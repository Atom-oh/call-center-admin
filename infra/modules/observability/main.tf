# Observability — SNS alerts topic, Slack relay Lambda, 5 metric alarms, 1 dashboard.
#
# Alarm coverage:
#   1. sfn_failure          — Step Functions ExecutionsFailed (any state-machine error)
#   2. classify_dlq_backlog — classify-side DLQ depth (Bedrock failure after retries)
#   3. persist_dlq_backlog  — persist-side DLQ depth (DDB write failure)
#   4. bedrock_throttle     — classify Lambda Errors (Bedrock 5xx / Throttling post-retry)
#   5. hitl_backlog         — custom EMF metric tracking pending-HITL count
#
# Slack delivery uses an inline Lambda (urllib.request → webhook). The webhook URL
# is read by envs/dev/main.tf from a Secrets Manager secret and passed in as a
# sensitive variable, never persisted in the module source.

terraform {
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 5.70" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }
}

#############################################
# SNS topic — single fan-out for all alarms #
#############################################

resource "aws_sns_topic" "alerts" {
  name = "callcenter-${var.env}-alerts"
}

##########################################################
# Slack relay Lambda — SNS Lambda subscriber → webhook   #
##########################################################

# Inline source: urllib-only, no third-party deps. Lambda runtime supplies stdlib.
data "archive_file" "slack_relay" {
  type        = "zip"
  output_path = "${path.module}/build/slack_relay.zip"
  source {
    filename = "handler.py"
    content  = <<-EOT
      """Inline Slack relay — receives SNS message, POSTs to incoming webhook.

      Stays under the AWS-managed 4MB request quota by truncating the message to 3500
      chars (Slack itself has its own 40k limit but truncating closer to the source
      keeps multi-alarm bundling readable). Failures are logged but never re-raised
      so a Slack outage cannot back up the SNS retry queue forever.
      """
      from __future__ import annotations

      import json
      import os
      import urllib.request

      WEBHOOK = os.environ["SLACK_WEBHOOK_URL"]
      _MAX = 3500


      def handler(event, _ctx):
          for record in event.get("Records", []):
              msg = record["Sns"]["Message"]
              try:
                  parsed = json.loads(msg)
                  name = parsed.get("AlarmName", "Alarm")
                  reason = parsed.get("NewStateReason", "")
                  text = f":warning: *{name}*\n{reason}"
              except Exception:
                  text = msg
              if len(text) > _MAX:
                  text = text[:_MAX] + " ... (truncated)"
              req = urllib.request.Request(
                  WEBHOOK,
                  data=json.dumps({"text": text}).encode(),
                  headers={"Content-Type": "application/json"},
              )
              try:
                  urllib.request.urlopen(req, timeout=10).read()
              except Exception as ex:
                  print(f"slack_relay: webhook delivery failed: {ex!r}")
          return {"ok": True}
    EOT
  }
}

resource "aws_iam_role" "slack_relay" {
  name = "callcenter-${var.env}-slack-relay"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Tight log scope — CW log group ARN only, not Resource="*".
resource "aws_cloudwatch_log_group" "slack_relay" {
  name              = "/aws/lambda/callcenter-${var.env}-slack-relay"
  retention_in_days = 14
}

resource "aws_iam_role_policy" "slack_relay" {
  role = aws_iam_role.slack_relay.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
      ]
      Resource = "${aws_cloudwatch_log_group.slack_relay.arn}:*"
    }]
  })
}

resource "aws_lambda_function" "slack_relay" {
  function_name    = "callcenter-${var.env}-slack-relay"
  role             = aws_iam_role.slack_relay.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.slack_relay.output_path
  source_code_hash = data.archive_file.slack_relay.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      SLACK_WEBHOOK_URL = var.slack_webhook_url
    }
  }

  # tracing_config + reserved_concurrency are intentionally omitted in Phase 1;
  # PR-prd can add tracing="Active" and reserved=2 for prod isolation.

  depends_on = [aws_cloudwatch_log_group.slack_relay]
}

resource "aws_sns_topic_subscription" "slack" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.slack_relay.arn
}

resource "aws_lambda_permission" "sns_invoke" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack_relay.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts.arn
}

##########################
# Alarms (5 in total)    #
##########################

# (1) Any Step Functions execution failure — primary indicator of pipeline health.
# Threshold 3 / 5min lets transient retries pass while catching sustained failures.
resource "aws_cloudwatch_metric_alarm" "sfn_failure" {
  alarm_name          = "callcenter-${var.env}-sfn-failure"
  alarm_description   = "SFN ExecutionsFailed >= 3 in 5m — see DLQ for stuck items."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ExecutionsFailed"
  namespace           = "AWS/States"
  period              = 300
  statistic           = "Sum"
  threshold           = 3
  treat_missing_data  = "notBreaching"

  dimensions = {
    StateMachineArn = var.sfn_arn
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# (2) Classify DLQ depth — Bedrock-side persistent error.
resource "aws_cloudwatch_metric_alarm" "classify_dlq_backlog" {
  alarm_name          = "callcenter-${var.env}-classify-dlq-backlog"
  alarm_description   = "Classify DLQ has > 10 messages — Bedrock failure post-retry."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 10
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = var.classify_dlq_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}

# (3) Persist DLQ depth — DDB write side failure.
resource "aws_cloudwatch_metric_alarm" "persist_dlq_backlog" {
  alarm_name          = "callcenter-${var.env}-persist-dlq-backlog"
  alarm_description   = "Persist DLQ has > 10 messages — DDB write failure post-retry."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 10
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = var.persist_dlq_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}

# (4) Bedrock Throttling — classify Lambda Errors over 1 min, sustained.
resource "aws_cloudwatch_metric_alarm" "bedrock_throttle" {
  alarm_name          = "callcenter-${var.env}-bedrock-throttle"
  alarm_description   = "classify Lambda Errors > 10 / 1m — likely Bedrock throttling."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = var.lambda_classify_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}

# (5) HITL backlog — custom EMF metric. evaluation_periods=12 datapoints_to_alarm=12
# = sustained > 100 for an hour (12 x 5min). One-off spikes ignored intentionally.
resource "aws_cloudwatch_metric_alarm" "hitl_backlog" {
  alarm_name          = "callcenter-${var.env}-hitl-backlog"
  alarm_description   = "HITL pending count > 100 for 60m — operations attention needed."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 12
  datapoints_to_alarm = 12
  metric_name         = "classification.hitlPending"
  namespace           = "callcenter/classification"
  period              = 300
  statistic           = "Maximum"
  threshold           = 100
  treat_missing_data  = "notBreaching"

  dimensions = {
    env = var.env
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}

##########################
# CloudWatch dashboard   #
##########################

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "callcenter-${var.env}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "분류 처리량 (시간당)"
          metrics = [["callcenter/classification", "classification.processed", "env", var.env]]
          period  = 3600
          stat    = "Sum"
          region  = "ap-northeast-2"
          view    = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "평균 confidence (5분)"
          metrics = [["callcenter/classification", "classify.confidence", "env", var.env]]
          period  = 300
          stat    = "Average"
          region  = "ap-northeast-2"
          view    = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title = "Step Functions 실행 결과"
          metrics = [
            ["AWS/States", "ExecutionsFailed", "StateMachineArn", var.sfn_arn, { label = "Failed" }],
            [".", "ExecutionsSucceeded", ".", ".", { label = "Succeeded" }],
            [".", "ExecutionsTimedOut", ".", ".", { label = "TimedOut" }],
          ]
          period = 300
          stat   = "Sum"
          region = "ap-northeast-2"
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title = "DLQ backlog"
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.classify_dlq_name, { label = "classify-dlq" }],
            [".", ".", ".", var.persist_dlq_name, { label = "persist-dlq" }],
          ]
          period = 60
          stat   = "Maximum"
          region = "ap-northeast-2"
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title = "Lambda Errors (4 functions)"
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", var.lambda_pii_name],
            [".", ".", ".", var.lambda_classify_name],
            [".", ".", ".", var.lambda_verify_name],
            [".", ".", ".", var.lambda_persist_name],
          ]
          period = 60
          stat   = "Sum"
          region = "ap-northeast-2"
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title = "PII 마스킹 적중 (per-type)"
          metrics = [
            ["callcenter/classification", "pii.maskApplied", "env", var.env, "pii_type", "phone"],
            [".", ".", ".", ".", ".", "rrn"],
            [".", ".", ".", ".", ".", "account"],
            [".", ".", ".", ".", ".", "card"],
          ]
          period = 300
          stat   = "Sum"
          region = "ap-northeast-2"
          view   = "timeSeries"
        }
      },
    ]
  })
}
