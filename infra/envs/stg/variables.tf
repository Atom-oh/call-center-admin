variable "env" {
  type        = string
  default     = "stg"
  description = "Staging environment — pre-prod canary."
}

# Atlantis cross-account AssumeRole target. Account-specific → terraform.tfvars
# (git-ignored). Empty string disables the assume_role block (local creds).
variable "terraformer_role_arn" {
  type        = string
  default     = ""
  description = "AssumeRole target ARN for the AWS provider. Empty disables assume_role."
}

variable "terraformer_external_id_secret" {
  type        = string
  default     = ""
  description = "Secrets Manager secret id for the AssumeRole ExternalId."
}

variable "hitl_acm_certificate_arn" {
  type        = string
  default     = ""
  description = "ACM ARN in ap-northeast-2 for the ALB HTTPS listener (authenticate-cognito)."
}

variable "hitl_acm_certificate_arn_us_east_1" {
  type        = string
  default     = ""
  description = "ACM ARN in us-east-1 for the CloudFront viewer certificate."
}

variable "hitl_callback_domain" {
  type        = string
  default     = ""
  description = "Public FQDN behind CloudFront."
}

variable "hitl_image_tag" {
  type        = string
  default     = "REPLACE_ME"
  description = "Immutable Streamlit container image tag (commit SHA)."
}
