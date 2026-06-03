variable "env" { type = string }

# Reserved for PR4+ (classify/verify/persist Lambdas in VPC, SFN integration).
# vpc_id + private_subnet_ids will wire into aws_lambda_function.*.vpc_config blocks.
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }

# PR3 (PII Guard) — actively used
variable "bucket_raw_arn" { type = string }
variable "bucket_masked_arn" { type = string }
variable "bucket_masked_id" { type = string }
variable "kms_raw_arn" { type = string }
variable "kms_masked_arn" { type = string }

# PR6 (persist Lambda DDB writes + SFN DLQ routing).
variable "ddb_consult_arn" { type = string }
variable "kms_ddb_arn" { type = string }
variable "classify_dlq_arn" { type = string }
variable "persist_dlq_arn" { type = string }

# Reserved for PR7 (Firehose Parquet). Empty string disables the put_record call.
variable "firehose_name" {
  type    = string
  default = ""
}

# PR7 (Firehose Parquet ARN — used to scope persist Lambda's firehose:PutRecord
# permission). Empty string keeps the PR6 broad "*" scope behavior so the module
# is backwards-compatible when analytics is not yet wired.
variable "firehose_arn" {
  type    = string
  default = ""
}

# ADR-002 (cache warming) — OPTIONAL, default OFF. When true, an EventBridge cron
# invokes the cache_warmer Lambda to keep the 2-breakpoint prompt cache warm.
# Adds zero AWS resources / zero recurring Bedrock cost when false.
variable "enable_cache_warming" {
  type    = bool
  default = false
}

# Cron interval — kept under Bedrock's ~5-min prompt-cache TTL. Only consulted
# when enable_cache_warming = true.
variable "cache_warming_schedule" {
  type    = string
  default = "rate(4 minutes)"
}
