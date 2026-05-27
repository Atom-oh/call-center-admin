variable "env" {
  type        = string
  description = "Deployment environment (dev / stg / prd)."
}

# Slack webhook 은 Secrets Manager 에 평문으로 저장되어 있고, envs/dev/main.tf
# 의 data source 로 읽혀 본 모듈에 전달된다. sensitive=true 로 표기해
# terraform plan 출력에 노출되지 않게 한다.
variable "slack_webhook_url" {
  type        = string
  description = "Slack incoming webhook URL — injected into the relay Lambda as env var."
  sensitive   = true
}

# classify-pipeline 모듈에서 outputs 으로 전달되는 식별자들.
variable "sfn_arn" {
  type        = string
  description = "Step Functions state machine ARN for the classify pipeline."
}

variable "classify_dlq_name" {
  type        = string
  description = "Name of the SQS DLQ for classify-side failures (used as CW dimension)."
}

variable "persist_dlq_name" {
  type        = string
  description = "Name of the SQS DLQ for persist-side failures (used as CW dimension)."
}

variable "lambda_classify_name" {
  type        = string
  description = "Lambda function name for classify (Bedrock Opus). Used for error alarm."
}

variable "lambda_verify_name" {
  type        = string
  description = "Lambda function name for verify (Bedrock Sonnet). Used for error alarm."
}

variable "lambda_persist_name" {
  type        = string
  description = "Lambda function name for persist (DDB writer). Used for error alarm."
}

variable "lambda_pii_name" {
  type        = string
  description = "Lambda function name for PII Guard. Used for PII regression alarm."
}
