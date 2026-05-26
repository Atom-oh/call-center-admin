terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
}

data "archive_file" "pii_guard" {
  type        = "zip"
  source_dir  = "${path.module}/../../../src"
  output_path = "${path.module}/build/pii_guard.zip"
  excludes = [
    "hitl_ui/**",
    "lambdas/classify/**",
    "lambdas/verify/**",
    "lambdas/persist/**",
    "prompts/**",
    "__pycache__/**",
    "**/__pycache__/**",
  ]
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
