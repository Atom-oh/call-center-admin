# Bootstrap stack: creates the S3 bucket + DDB lock table that all other
# call-center-admin terraform stacks (infra/envs/{dev,stg,prd}) use as their
# remote backend. This stack itself has NO remote backend — local state is
# the bootstrap chicken-and-egg solution.
#
# Driven by Atlantis as a registered project (atlantis.yaml: shared-state).
# Apply path: open PR touching infra/shared-state/*.tf → atlantis plan →
# review → atlantis apply -p shared-state → S3 + DDB created.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
}

provider "aws" {
  region = "ap-northeast-2"
  default_tags {
    tags = {
      project    = "callcenter-classification"
      component  = "shared-state"
      managed-by = "terraform"
    }
  }
}

resource "aws_s3_bucket" "tfstate" {
  bucket = "kakaopay-callcenter-tfstate"
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tflock" {
  name         = "kakaopay-callcenter-tflock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
}
