variable "env" {
  type        = string
  default     = "prd"
  description = "Production environment."
}

# Atlantis cross-account AssumeRole — same target as dev/stg. prd-specific
# hardening (e.g. ECS desired_count >= 2) lives in a separate hardening PR.
variable "terraformer_role_arn" {
  type        = string
  default     = "arn:aws:iam::<ACCOUNT_ID>:role/<TERRAFORMER_ROLE>"
  description = "AssumeRole target for the AWS provider."
}
