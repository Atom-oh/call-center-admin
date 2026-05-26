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
      MODEL_ID   = "anthropic.claude-opus-4-7-20260101-v1:0"
      PROMPT_DIR = "/var/task/prompts/v1.0"
    }
  }

  depends_on = [aws_cloudwatch_log_group.classify]
}
