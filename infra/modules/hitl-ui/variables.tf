variable "env" {
  type        = string
  description = "Deployment environment (dev / stg / prd)."
}

variable "vpc_id" {
  type        = string
  description = "VPC ID — ALB + ECS tasks attach here."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs — at least 2 AZs for ALB + ECS HA."
}

variable "ddb_consult_arn" {
  type        = string
  description = "Consult-results DDB table ARN — IAM Resource scope for HITL queries."
}

variable "bucket_masked_arn" {
  type        = string
  description = "S3 stt-masked bucket ARN — transcript display."
}

variable "bucket_raw_arn" {
  type        = string
  description = "S3 stt-raw bucket ARN — compliance presigned download."
}

variable "kms_ddb_arn" {
  type        = string
  description = "KMS CMK for DDB — required for DDB read/write encryption."
}

variable "kms_masked_arn" {
  type        = string
  description = "KMS CMK for S3 stt-masked — required for transcript decrypt."
}

variable "kms_raw_arn" {
  type        = string
  description = "KMS CMK for S3 stt-raw — required for compliance presigned URL decrypt."
}

# Reserved for PR10 (CI/CD) — ACM cert ARN passed in once cert is issued.
variable "acm_certificate_arn" {
  type        = string
  default     = ""
  description = "Internal ACM certificate ARN. When empty, the ALB listener is HTTP-only (lab use)."
}
