terraform {
  required_version = ">= 1.6"
  # Shared multi-project tfstate bucket — same physical bucket used by
  # Atom-oh/AWS-Demo-Platform and Atom-oh/multi-region-architecture.
  # Per-project isolation is by key prefix.
  # Note: bucket + DDB lock physically live in us-east-1, but the actual
  # AWS resources this stack provisions are still in ap-northeast-2
  # (provider region in main.tf).
  backend "s3" {
    bucket         = "multi-region-mall-terraform-state"
    key            = "call-center-admin/envs/dev.tfstate"
    region         = "us-east-1"
    dynamodb_table = "multi-region-mall-terraform-locks"
    encrypt        = true
  }
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
}
