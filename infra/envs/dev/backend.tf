terraform {
  required_version = ">= 1.6"
  # Shared Atlantis-managed tfstate bucket in ap-northeast-2. Bucket is
  # CLI-bootstrapped (one-time) and shared across all Atlantis-managed
  # projects under this account. Per-project isolation by key prefix.
  #
  # No `dynamodb_table` — non-prod / single operator, state locking
  # via DDB not needed. TF 1.10+ `use_lockfile = true` is the cleaner
  # native-S3 alternative; will switch when Atlantis image bundles 1.10+.
  backend "s3" {
    bucket  = "atom-oh-atlantis-tfstate-apne2"
    key     = "call-center-admin/envs/dev.tfstate"
    region  = "ap-northeast-2"
    encrypt = true
  }
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
}
