variable "env" {
  type        = string
  description = "Deployment environment (dev / stg / prd)."
}

# Slack webhook 은 Secrets Manager 에 사전 등록되어 있고, envs/{env}/main.tf 의
# data source 가 secret_string 을 읽어 본 모듈에 전달한다. sensitive=true 로
# terraform plan 출력에서 redact 되도록 강제 — Decision-G1.
variable "slack_webhook_url" {
  type        = string
  description = "Slack incoming webhook URL — passed to relay Lambda as env var. Sensitive."
  sensitive   = true
}

# spec §2.2 의 5 알람이 참조하는 외부 식별자.
variable "sfn_arn" {
  type        = string
  description = "Step Functions state machine ARN (sfn_failure alarm dim)."
}

variable "classify_dlq_name" {
  type        = string
  description = "Classify-side SQS DLQ name (classify_dlq_backlog alarm dim)."
}

variable "persist_dlq_name" {
  type        = string
  description = "Persist-side SQS DLQ name (persist_dlq_backlog alarm dim)."
}

variable "lambda_classify_name" {
  type        = string
  description = "Classify Lambda name (bedrock_throttle alarm dim)."
}

variable "lambda_verify_name" {
  type        = string
  description = "Verify Lambda name (dashboard widget 5)."
}

variable "lambda_persist_name" {
  type        = string
  description = "Persist Lambda name (dashboard widget 5)."
}

variable "lambda_pii_name" {
  type        = string
  description = "PII Guard Lambda name (dashboard widget 5)."
}
