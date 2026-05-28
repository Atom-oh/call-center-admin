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

# Image tag for the Streamlit container. The ECR repository is IMMUTABLE (G8),
# so the same tag can never be pushed twice. PR10 CI/CD injects the commit SHA
# (or an explicit semver). The default is a placeholder that fails loudly if
# the caller forgets — `latest` would silently collide on the second build
# (M1 from AI Code Review).
variable "image_tag" {
  type        = string
  default     = "REPLACE_ME"
  description = "Immutable container image tag (e.g. commit SHA). Required at deploy time."
}

# ALB region for OIDC public key fetch (JWT signature verification).
variable "alb_region" {
  type        = string
  default     = "ap-northeast-2"
  description = "ALB region — used to resolve public-keys.auth.elb.{region}.amazonaws.com for JWT verification."
}

# CloudWatch retention. Finance domain typically requires 1–3 years. Split so
# the (cheaper) app logs can rotate faster while audit logs stay longer.
variable "log_retention_days" {
  type        = number
  default     = 90
  description = "Retention for the application log group (Streamlit stdout)."
}

variable "audit_retention_days" {
  type        = number
  default     = 365
  description = "Retention for the audit log group (HITL correction / compliance download events)."
}
