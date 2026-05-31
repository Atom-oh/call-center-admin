variable "env" {
  type    = string
  default = "dev"
}

# Atlantis cross-account AssumeRole target. Account-specific — supply via
# terraform.tfvars (git-ignored). Empty string disables the assume_role block
# (local runs with direct IAM credentials).
variable "terraformer_role_arn" {
  type        = string
  default     = ""
  description = "AssumeRole target ARN for the AWS provider. Empty disables assume_role."
}

# Secrets Manager id holding the ExternalId for the AssumeRole. Account-specific.
variable "terraformer_external_id_secret" {
  type        = string
  default     = ""
  description = "Secrets Manager secret id for the AssumeRole ExternalId. Empty when terraformer_role_arn is empty."
}

# HITL UI — ACM certs + domain. All account/domain-specific → terraform.tfvars.
# Empty values keep the HITL UI in skeleton state (no listener / ECS / CloudFront).
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
  description = "Public FQDN behind CloudFront (e.g. callcenter-dev-hitl.example.com)."
}

variable "hitl_image_tag" {
  type        = string
  default     = "REPLACE_ME"
  description = "Immutable Streamlit container image tag (commit SHA)."
}
