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

# ADR-013 정정: ALB authenticate-cognito 는 HTTPS listener 전용이라 ALB 에
# ap-northeast-2 ACM cert 가 필요. CloudFront VPC Origin 이 ALB 와 HTTPS 통신.
# 빈 값이면 ALB listener + ECS service 가 gate off (cert 발급 전 skeleton 상태).
variable "acm_certificate_arn" {
  type        = string
  default     = ""
  description = "ACM ARN in the ALB region (ap-northeast-2) for the HTTPS listener (authenticate-cognito). Empty → no listener / ECS service."
}

# ADR-013: CloudFront viewer cert lives in us-east-1 (CloudFront requirement).
# Default empty so the CF distribution is gated off until the cert is issued.
variable "acm_certificate_arn_us_east_1" {
  type        = string
  default     = ""
  description = "Public ACM ARN in us-east-1 for the CloudFront distribution. Empty → CF disabled."
}

# Image tag for the Streamlit container. The ECR repository is IMMUTABLE (G8),
# so the same tag can never be pushed twice. PR10 CI/CD injects the commit SHA.
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

# CloudWatch retention. Finance domain typically requires 1-3 years. Split so
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

# ADR-013: callback domain is the CloudFront alias (public domain).
# Default kept as placeholder so deploy time injects the actual FQDN.
variable "callback_domain" {
  type        = string
  default     = "REPLACE_ME"
  description = "Public FQDN behind CloudFront (e.g. hitl.callcenter-dev.kakaopay.com). Used to build the Cognito callback URL and the CloudFront viewer alias."
}

# CloudFront WAF — toggle. When false, CF is created without a WAF web ACL.
variable "enable_waf" {
  type        = bool
  default     = true
  description = "Attach an AWS-managed WAF v2 web ACL to the CloudFront distribution."
}
