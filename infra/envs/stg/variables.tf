variable "env" {
  type        = string
  default     = "stg"
  description = "Staging environment — pre-prod canary."
}

# Atlantis cross-account AssumeRole — same target as dev (atomoh-main account
# hosts all envs). Empty string disables the assume_role block for local dev /
# alternative CI runners.
variable "terraformer_role_arn" {
  type        = string
  default     = "arn:aws:iam::180294183052:role/DemoPlatformTerraformer"
  description = "AssumeRole target for the AWS provider."
}
