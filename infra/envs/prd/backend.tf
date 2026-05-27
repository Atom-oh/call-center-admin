terraform {
  required_version = ">= 1.6"
  # Shared Atlantis-managed tfstate bucket in ap-northeast-2.
  # Per-env isolation via key suffix (envs/prd.tfstate).
  backend "s3" {
    bucket  = "atom-oh-atlantis-tfstate-apne2"
    key     = "call-center-admin/envs/prd.tfstate"
    region  = "ap-northeast-2"
    encrypt = true
  }
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
}
