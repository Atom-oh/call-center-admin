terraform {
  required_version = ">= 1.6"
  # OSS: bucket / key via partial backend config.
  #   terraform init -backend-config=backend.hcl
  backend "s3" {
    region  = "ap-northeast-2"
    encrypt = true
  }
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
}
