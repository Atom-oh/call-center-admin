terraform {
  required_version = ">= 1.6"
  # Shared multi-project tfstate bucket — same physical bucket used by
  # Atom-oh/<INFRA_REPO> and Atom-oh/multi-region-architecture.
  # Per-project isolation is by key prefix.
  backend "s3" {
    bucket         = "<LEGACY_TFSTATE_BUCKET>"
    key            = "call-center-admin/envs/dev.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "<LEGACY_TFSTATE_LOCK_TABLE>"
    encrypt        = true
  }
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
}
