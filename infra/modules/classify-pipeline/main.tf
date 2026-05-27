terraform {
  required_providers {
    aws      = { source = "hashicorp/aws", version = "~> 5.70" }
    archive  = { source = "hashicorp/archive", version = "~> 2.4" }
    external = { source = "hashicorp/external", version = "~> 2.3" }
  }
}

# ---------- Per-Lambda staging dirs ----------
# 각 Lambda는 자신의 staging dir(`build/{name}/`)에 필요한 파일만 복사한 뒤 zip.
# 이렇게 하면 같은 src/ 트리에서 만들어도 Lambda별로 zip에 들어가는 모듈 set가 분리되어
# - 콜드 스타트 사이즈 감소
# - 미사용 코드 attack surface 감소
# - PR4+에서 새 Lambda 추가 시 exclude 리스트 유지 필요 없음

data "external" "pii_guard_stage" {
  program = ["bash", "-c", <<-EOT
    set -e
    STAGE_DIR=${path.module}/build/pii_guard
    SRC_DIR=${path.module}/../../../src
    rm -rf "$STAGE_DIR"
    mkdir -p "$STAGE_DIR"
    cp -R "$SRC_DIR/lib" "$STAGE_DIR/"
    mkdir -p "$STAGE_DIR/lambdas"
    cp -R "$SRC_DIR/lambdas/pii_guard" "$STAGE_DIR/lambdas/"
    find "$STAGE_DIR" -type d -name __pycache__ -exec rm -rf {} + || true
    echo "{\"staged\":\"$STAGE_DIR\"}"
  EOT
  ]
}

data "archive_file" "pii_guard" {
  type        = "zip"
  source_dir  = data.external.pii_guard_stage.result.staged
  output_path = "${path.module}/build/pii_guard.zip"
}

data "external" "classify_stage" {
  program = ["bash", "-c", <<-EOT
    set -e
    STAGE_DIR=${path.module}/build/classify
    SRC_DIR=${path.module}/../../../src
    rm -rf "$STAGE_DIR"
    mkdir -p "$STAGE_DIR"
    cp -R "$SRC_DIR/lib" "$STAGE_DIR/"
    cp -R "$SRC_DIR/prompts" "$STAGE_DIR/"
    mkdir -p "$STAGE_DIR/lambdas"
    cp -R "$SRC_DIR/lambdas/classify" "$STAGE_DIR/lambdas/"
    find "$STAGE_DIR" -type d -name __pycache__ -exec rm -rf {} + || true
    echo "{\"staged\":\"$STAGE_DIR\"}"
  EOT
  ]
}

data "archive_file" "classify" {
  type        = "zip"
  source_dir  = data.external.classify_stage.result.staged
  output_path = "${path.module}/build/classify.zip"
}

data "external" "verify_stage" {
  program = ["bash", "-c", <<-EOT
    set -e
    STAGE_DIR=${path.module}/build/verify
    SRC_DIR=${path.module}/../../../src
    rm -rf "$STAGE_DIR"
    mkdir -p "$STAGE_DIR"
    cp -R "$SRC_DIR/lib" "$STAGE_DIR/"
    cp -R "$SRC_DIR/prompts" "$STAGE_DIR/"
    mkdir -p "$STAGE_DIR/lambdas"
    cp -R "$SRC_DIR/lambdas/verify" "$STAGE_DIR/lambdas/"
    find "$STAGE_DIR" -type d -name __pycache__ -exec rm -rf {} + || true
    echo "{\"staged\":\"$STAGE_DIR\"}"
  EOT
  ]
}

data "archive_file" "verify" {
  type        = "zip"
  source_dir  = data.external.verify_stage.result.staged
  output_path = "${path.module}/build/verify.zip"
}

resource "aws_iam_role" "pii_guard" {
  name = "callcenter-${var.env}-pii-guard"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "pii_guard" {
  role = aws_iam_role.pii_guard.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${var.bucket_raw_arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${var.bucket_masked_arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = var.kms_raw_arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:GenerateDataKey"]
        Resource = var.kms_masked_arn
      },
      {
        # Log group is pre-created (aws_cloudwatch_log_group.pii_guard) so we omit
        # logs:CreateLogGroup and tighten Resource to the specific stream pattern.
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.pii_guard.arn}:*"
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "pii_guard" {
  name              = "/aws/lambda/callcenter-${var.env}-pii-guard"
  retention_in_days = 30
}

resource "aws_lambda_function" "pii_guard" {
  function_name    = "callcenter-${var.env}-pii-guard"
  role             = aws_iam_role.pii_guard.arn
  handler          = "lambdas.pii_guard.handler.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.pii_guard.output_path
  source_code_hash = data.archive_file.pii_guard.output_base64sha256
  timeout          = 60
  memory_size      = 512

  environment {
    variables = {
      MASKED_BUCKET = var.bucket_masked_id
    }
  }

  depends_on = [aws_cloudwatch_log_group.pii_guard]
}

# ---------- Classify Lambda ----------

resource "aws_iam_role" "classify" {
  name = "callcenter-${var.env}-classify"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "classify" {
  role = aws_iam_role.classify.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${var.bucket_masked_arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = var.kms_masked_arn
      },
      {
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = "arn:aws:bedrock:ap-northeast-2::foundation-model/anthropic.claude-opus-4-*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.classify.arn}:*"
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "classify" {
  name              = "/aws/lambda/callcenter-${var.env}-classify"
  retention_in_days = 30
}

resource "aws_lambda_function" "classify" {
  function_name    = "callcenter-${var.env}-classify"
  role             = aws_iam_role.classify.arn
  handler          = "lambdas.classify.handler.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.classify.output_path
  source_code_hash = data.archive_file.classify.output_base64sha256
  timeout          = 300
  memory_size      = 1024

  environment {
    variables = {
      MODEL_ID   = "apac.anthropic.claude-opus-4-7-20260101-v1:0"
      PROMPT_DIR = "/var/task/prompts/v1.0"
    }
  }

  depends_on = [aws_cloudwatch_log_group.classify]
}

# ---------- Verify Lambda ----------

resource "aws_iam_role" "verify" {
  name = "callcenter-${var.env}-verify"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "verify" {
  role = aws_iam_role.verify.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${var.bucket_masked_arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = var.kms_masked_arn
      },
      {
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = "arn:aws:bedrock:ap-northeast-2::foundation-model/anthropic.claude-sonnet-4-*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.verify.arn}:*"
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "verify" {
  name              = "/aws/lambda/callcenter-${var.env}-verify"
  retention_in_days = 30
}

resource "aws_lambda_function" "verify" {
  function_name    = "callcenter-${var.env}-verify"
  role             = aws_iam_role.verify.arn
  handler          = "lambdas.verify.handler.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.verify.output_path
  source_code_hash = data.archive_file.verify.output_base64sha256
  timeout          = 300
  memory_size      = 1024

  environment {
    variables = {
      VERIFY_MODEL_ID = "apac.anthropic.claude-sonnet-4-6-20260101-v1:0"
      PROMPT_DIR      = "/var/task/prompts/v1.0"
    }
  }

  depends_on = [aws_cloudwatch_log_group.verify]
}

# ---------- Persist Lambda staging + zip ----------

data "external" "persist_stage" {
  program = ["bash", "-c", <<-EOT
    set -e
    STAGE_DIR=${path.module}/build/persist
    SRC_DIR=${path.module}/../../../src
    rm -rf "$STAGE_DIR"
    mkdir -p "$STAGE_DIR"
    cp -R "$SRC_DIR/lib" "$STAGE_DIR/"
    mkdir -p "$STAGE_DIR/lambdas"
    cp -R "$SRC_DIR/lambdas/persist" "$STAGE_DIR/lambdas/"
    find "$STAGE_DIR" -type d -name __pycache__ -exec rm -rf {} + || true
    echo "{\"staged\":\"$STAGE_DIR\"}"
  EOT
  ]
}

data "archive_file" "persist" {
  type        = "zip"
  source_dir  = data.external.persist_stage.result.staged
  output_path = "${path.module}/build/persist.zip"
}

# ---------- Persist Lambda ----------

resource "aws_iam_role" "persist" {
  name = "callcenter-${var.env}-persist"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "persist" {
  role = aws_iam_role.persist.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem"]
        Resource = var.ddb_consult_arn
      },
      {
        # Scope KMS to the DDB CMK only — persist Lambda writes encrypted items
        # to consult-results and does not touch other CMKs.
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey"]
        Resource = var.kms_ddb_arn
      },
      {
        # PR7 will narrow this to the specific delivery stream ARN once
        # firehose_name is populated. With firehose_name="" the persist
        # handler skips put_record entirely, so this allow-all is dormant.
        Effect   = "Allow"
        Action   = ["firehose:PutRecord", "firehose:PutRecordBatch"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.persist.arn}:*"
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "persist" {
  name              = "/aws/lambda/callcenter-${var.env}-persist"
  retention_in_days = 30
}

resource "aws_lambda_function" "persist" {
  function_name    = "callcenter-${var.env}-persist"
  role             = aws_iam_role.persist.arn
  handler          = "lambdas.persist.handler.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.persist.output_path
  source_code_hash = data.archive_file.persist.output_base64sha256
  timeout          = 60
  memory_size      = 512

  environment {
    variables = {
      DDB_TABLE     = "callcenter-${var.env}-consult-results"
      FIREHOSE_NAME = var.firehose_name
    }
  }

  depends_on = [aws_cloudwatch_log_group.persist]
}

# ---------- Step Functions Express state machine ----------

resource "aws_iam_role" "sfn" {
  name = "callcenter-${var.env}-sfn"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "sfn" {
  role = aws_iam_role.sfn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        Resource = [
          aws_lambda_function.pii_guard.arn,
          aws_lambda_function.classify.arn,
          aws_lambda_function.verify.arn,
          aws_lambda_function.persist.arn,
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = [var.classify_dlq_arn, var.persist_dlq_arn]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery", "logs:GetLogDelivery", "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery", "logs:ListLogDeliveries", "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies", "logs:DescribeLogGroups",
          "logs:CreateLogStream", "logs:PutLogEvents",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/states/callcenter-${var.env}-classify"
  retention_in_days = 30
}

locals {
  classify_dlq_url = replace(
    var.classify_dlq_arn,
    "arn:aws:sqs:ap-northeast-2:",
    "https://sqs.ap-northeast-2.amazonaws.com/"
  )
  persist_dlq_url = replace(
    var.persist_dlq_arn,
    "arn:aws:sqs:ap-northeast-2:",
    "https://sqs.ap-northeast-2.amazonaws.com/"
  )
}

resource "aws_sfn_state_machine" "classify" {
  name     = "callcenter-${var.env}-classify"
  role_arn = aws_iam_role.sfn.arn
  type     = "EXPRESS"

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  definition = jsonencode({
    Comment = "콜센터 STT 자동 분류 — PR6"
    StartAt = "PiiGuard"
    States = {
      PiiGuard = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.pii_guard.arn
          "Payload.$"  = "$"
        }
        ResultSelector = { "result.$" = "$.Payload" }
        OutputPath     = "$.result"
        Retry = [{
          ErrorEquals     = ["States.TaskFailed"]
          IntervalSeconds = 2
          MaxAttempts     = 3
          BackoffRate     = 2.0
        }]
        Next = "Classify"
      }
      Classify = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.classify.arn
          "Payload.$"  = "$"
        }
        ResultSelector = { "result.$" = "$.Payload" }
        OutputPath     = "$.result"
        Retry = [{
          ErrorEquals     = ["States.TaskFailed", "ThrottlingException", "ServiceUnavailable"]
          IntervalSeconds = 1
          MaxAttempts     = 5
          BackoffRate     = 2.0
        }]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "SendToClassifyDlq"
          ResultPath  = "$.errorInfo"
        }]
        Next = "ConfidenceBranch"
      }
      ConfidenceBranch = {
        Type = "Choice"
        Choices = [{
          Variable        = "$.classification.confidence"
          NumericLessThan = 0.80
          Next            = "Verify"
        }]
        Default = "MarkAutoHigh"
      }
      MarkAutoHigh = {
        Type = "Pass"
        Parameters = {
          "callId.$"         = "$.callId"
          "agentId.$"        = "$.agentId"
          "startedAt.$"      = "$.startedAt"
          "durationSec.$"    = "$.durationSec"
          "rawBucket.$"      = "$.rawBucket"
          "rawKey.$"         = "$.rawKey"
          "maskedBucket.$"   = "$.maskedBucket"
          "maskedKey.$"      = "$.maskedKey"
          "modelId.$"        = "$.modelId"
          "promptVersion.$"  = "$.promptVersion"
          "classification.$" = "$.classification"
          verified           = "auto-high"
          status             = "confirmed"
          "modelPath.$"      = "States.Array($.modelId)"
        }
        Next = "Persist"
      }
      Verify = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.verify.arn
          "Payload.$"  = "$"
        }
        ResultSelector = { "result.$" = "$.Payload" }
        OutputPath     = "$.result"
        Retry = [{
          ErrorEquals     = ["States.TaskFailed"]
          IntervalSeconds = 2
          MaxAttempts     = 3
          BackoffRate     = 2.0
        }]
        Next = "Persist"
      }
      Persist = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.persist.arn
          "Payload.$"  = "$"
        }
        ResultSelector = { "result.$" = "$.Payload" }
        OutputPath     = "$.result"
        Retry = [{
          ErrorEquals     = ["States.TaskFailed"]
          IntervalSeconds = 1
          MaxAttempts     = 3
          BackoffRate     = 2.0
        }]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "SendToPersistDlq"
          ResultPath  = "$.errorInfo"
        }]
        End = true
      }
      SendToClassifyDlq = {
        Type     = "Task"
        Resource = "arn:aws:states:::sqs:sendMessage"
        Parameters = {
          QueueUrl        = local.classify_dlq_url
          "MessageBody.$" = "$"
        }
        End = true
      }
      SendToPersistDlq = {
        Type     = "Task"
        Resource = "arn:aws:states:::sqs:sendMessage"
        Parameters = {
          QueueUrl        = local.persist_dlq_url
          "MessageBody.$" = "$"
        }
        End = true
      }
    }
  })

  depends_on = [aws_cloudwatch_log_group.sfn]
}

# ---------- EventBridge S3 trigger ----------

resource "aws_s3_bucket_notification" "raw" {
  bucket      = element(split(":", var.bucket_raw_arn), 5)
  eventbridge = true
}

resource "aws_iam_role" "eventbridge" {
  name = "callcenter-${var.env}-eb-to-sfn"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "eventbridge_to_sfn" {
  role = aws_iam_role.eventbridge.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["states:StartExecution"]
      Resource = aws_sfn_state_machine.classify.arn
    }]
  })
}

resource "aws_cloudwatch_event_rule" "s3_raw_put" {
  name = "callcenter-${var.env}-raw-put"
  event_pattern = jsonencode({
    source        = ["aws.s3"]
    "detail-type" = ["Object Created"]
    detail = {
      bucket = { name = [element(split(":", var.bucket_raw_arn), 5)] }
      object = { key = [{ suffix = ".json" }] }
    }
  })
}

resource "aws_cloudwatch_event_target" "to_sfn" {
  rule     = aws_cloudwatch_event_rule.s3_raw_put.name
  arn      = aws_sfn_state_machine.classify.arn
  role_arn = aws_iam_role.eventbridge.arn

  input_transformer {
    input_paths = {
      bucket = "$.detail.bucket.name"
      key    = "$.detail.object.key"
    }
    input_template = "{\"rawBucket\":<bucket>,\"rawKey\":<key>}"
  }
}
