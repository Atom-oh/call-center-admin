terraform {
  required_version = ">= 1.6"
  # OSS: bucket / key are account-specific → supplied via partial backend config.
  #   terraform init -backend-config=backend.hcl
  # See backend.hcl.example. (`backend.hcl` is git-ignored.)
  #
  # No `dynamodb_table` — non-prod / single operator, state locking via DDB not
  # needed. TF 1.10+ `use_lockfile = true` is the cleaner native-S3 alternative.
  backend "s3" {
    region  = "ap-northeast-2"
    encrypt = true
  }
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
}
