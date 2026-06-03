terraform {
  required_providers {
    aws      = { source = "hashicorp/aws", version = "~> 5.70" }
    archive  = { source = "hashicorp/archive", version = "~> 2.4" }
    external = { source = "hashicorp/external", version = "~> 2.3" }
  }
}

data "aws_caller_identity" "current" {}

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
        # Bedrock CRIS (global.anthropic.claude-opus-4-7) routes through
        # an inference-profile resource AND the underlying foundation
        # models in routed regions. Both ARN types are required.
        Effect = "Allow"
        Action = ["bedrock:InvokeModel"]
        Resource = [
          "arn:aws:bedrock:ap-northeast-2:${data.aws_caller_identity.current.account_id}:inference-profile/global.anthropic.claude-opus-4-7",
          "arn:aws:bedrock:*::foundation-model/anthropic.claude-opus-4-*"
        ]
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
      MODEL_ID   = "global.anthropic.claude-opus-4-7"
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
        # Bedrock CRIS (global.anthropic.claude-sonnet-4-6) — same dual-ARN
        # pattern as classify Lambda.
        Effect = "Allow"
        Action = ["bedrock:InvokeModel"]
        Resource = [
          "arn:aws:bedrock:ap-northeast-2:${data.aws_caller_identity.current.account_id}:inference-profile/global.anthropic.claude-sonnet-4-6",
          "arn:aws:bedrock:*::foundation-model/anthropic.claude-sonnet-4-*"
        ]
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
      VERIFY_MODEL_ID = "global.anthropic.claude-sonnet-4-6"
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
        # PR7 narrows this to the specific delivery stream ARN once firehose_arn is set.
        # With firehose_arn="" the persist handler skips put_record entirely and this
        # allow-all is dormant.
        Effect   = "Allow"
        Action   = ["firehose:PutRecord", "firehose:PutRecordBatch"]
        Resource = var.firehose_arn != "" ? var.firehose_arn : "*"
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
  # SQS ARN format: arn:aws:sqs:REGION:ACCOUNT:QUEUE_NAME
  # SQS URL format: https://sqs.REGION.amazonaws.com/ACCOUNT/QUEUE_NAME
  # The previous `replace()` only stripped the prefix and left the `:`
  # between account and queue name, producing an invalid URL like
  # `https://sqs.ap-northeast-2.amazonaws.com/<ACCOUNT_ID>:callcenter-dev-classify-dlq`
  # which SFN treats as a non-existent queue.
  classify_dlq_parts = split(":", var.classify_dlq_arn)
  classify_dlq_url   = "https://sqs.${local.classify_dlq_parts[3]}.amazonaws.com/${local.classify_dlq_parts[4]}/${local.classify_dlq_parts[5]}"
  persist_dlq_parts  = split(":", var.persist_dlq_arn)
  persist_dlq_url    = "https://sqs.${local.persist_dlq_parts[3]}.amazonaws.com/${local.persist_dlq_parts[4]}/${local.persist_dlq_parts[5]}"
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

# ==========================================================================
# ADR-002: OPTIONAL cache-warming (EventBridge cron + warmer Lambda).
# Every AWS resource is count-gated on var.enable_cache_warming (default false)
# → zero resources / zero recurring Bedrock cost unless explicitly enabled.
# The warmer reuses the SAME 2-breakpoint system blocks + MODEL_ID as classify
# (lib.bedrock_client.warm()) so it warms the exact cache classify reads.
# ==========================================================================

# stage + zip are ALSO count-gated on the same var so a default-OFF environment
# does zero build I/O (no rm -rf / cp -R) on every plan. When enabled, both have
# index [0] alongside the aws_lambda_function below.
data "external" "cache_warmer_stage" {
  count = var.enable_cache_warming ? 1 : 0
  program = ["bash", "-c", <<-EOT
    set -e
    STAGE_DIR=${path.module}/build/cache_warmer
    SRC_DIR=${path.module}/../../../src
    rm -rf "$STAGE_DIR"
    mkdir -p "$STAGE_DIR"
    cp -R "$SRC_DIR/lib" "$STAGE_DIR/"
    cp -R "$SRC_DIR/prompts" "$STAGE_DIR/"
    mkdir -p "$STAGE_DIR/lambdas"
    cp -R "$SRC_DIR/lambdas/cache_warmer" "$STAGE_DIR/lambdas/"
    find "$STAGE_DIR" -type d -name __pycache__ -exec rm -rf {} + || true
    echo "{\"staged\":\"$STAGE_DIR\"}"
  EOT
  ]
}

data "archive_file" "cache_warmer" {
  count       = var.enable_cache_warming ? 1 : 0
  type        = "zip"
  source_dir  = data.external.cache_warmer_stage[0].result.staged
  output_path = "${path.module}/build/cache_warmer.zip"
}

resource "aws_iam_role" "cache_warmer" {
  count = var.enable_cache_warming ? 1 : 0
  name  = "callcenter-${var.env}-cache-warmer"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "cache_warmer" {
  count = var.enable_cache_warming ? 1 : 0
  role  = aws_iam_role.cache_warmer[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Same opus inference-profile + foundation-model ARNs as classify (ADR-010).
        # NO kms/s3/dynamodb (ADR-006 least-privilege — warmer only pings Bedrock).
        Effect = "Allow"
        Action = ["bedrock:InvokeModel"]
        Resource = [
          "arn:aws:bedrock:ap-northeast-2:${data.aws_caller_identity.current.account_id}:inference-profile/global.anthropic.claude-opus-4-7",
          "arn:aws:bedrock:*::foundation-model/anthropic.claude-opus-4-*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.cache_warmer[0].arn}:*"
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "cache_warmer" {
  count             = var.enable_cache_warming ? 1 : 0
  name              = "/aws/lambda/callcenter-${var.env}-cache-warmer"
  retention_in_days = 30
}

resource "aws_lambda_function" "cache_warmer" {
  count            = var.enable_cache_warming ? 1 : 0
  function_name    = "callcenter-${var.env}-cache-warmer"
  role             = aws_iam_role.cache_warmer[0].arn
  handler          = "lambdas.cache_warmer.handler.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.cache_warmer[0].output_path
  source_code_hash = data.archive_file.cache_warmer[0].output_base64sha256
  timeout          = 60
  memory_size      = 512

  environment {
    variables = {
      MODEL_ID   = "global.anthropic.claude-opus-4-7"
      PROMPT_DIR = "/var/task/prompts/v1.0"
    }
  }

  depends_on = [aws_cloudwatch_log_group.cache_warmer]
}

resource "aws_cloudwatch_event_rule" "cache_warm" {
  count               = var.enable_cache_warming ? 1 : 0
  name                = "callcenter-${var.env}-cache-warm"
  schedule_expression = var.cache_warming_schedule
}

resource "aws_cloudwatch_event_target" "cache_warm" {
  count = var.enable_cache_warming ? 1 : 0
  rule  = aws_cloudwatch_event_rule.cache_warm[0].name
  arn   = aws_lambda_function.cache_warmer[0].arn
}

resource "aws_lambda_permission" "cache_warm_events" {
  count         = var.enable_cache_warming ? 1 : 0
  statement_id  = "AllowEventBridgeInvokeCacheWarmer"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cache_warmer[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.cache_warm[0].arn
}
