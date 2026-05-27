terraform {
  required_version = ">= 1.6"
  # Shared Atlantis-managed tfstate bucket in ap-northeast-2. Created by
  # `infra/shared-state/` (apply that stack first via Atlantis). All future
  # Atlantis-managed projects under this account use the same bucket with
  # a key prefix for isolation.
  backend "s3" {
    bucket         = "<YOUR_TFSTATE_BUCKET>"
    key            = "call-center-admin/envs/dev.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "<YOUR_TFSTATE_LOCK_TABLE>"
    encrypt        = true
  }
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
}
