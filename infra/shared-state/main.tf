# Bootstrap stack: creates the shared S3 tfstate bucket + DDB lock table
# for ALL Atlantis-managed projects going forward.
#
# Bucket lives in ap-northeast-2 (data residency).
# This stack itself has NO remote backend — local state is the bootstrap
# chicken-and-egg solution. Atlantis keeps the workspace per PR so the
# state file persists from plan to apply on the same PR; after apply the
# bucket exists and subsequent runs use it.
#
# Driven by Atlantis as a registered project (atlantis.yaml: shared-state).

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
      project    = "atlantis-managed"
      component  = "shared-tfstate"
      managed-by = "terraform"
      owner      = "atom-oh"
    }
  }
}

# S3 bucket name must be globally unique. Using org-prefixed name keeps
# it unique without account ID exposure.
resource "aws_s3_bucket" "tfstate" {
  bucket = "<YOUR_TFSTATE_BUCKET>"
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
  name         = "<YOUR_TFSTATE_LOCK_TABLE>"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
}

output "bucket_name" {
  value = aws_s3_bucket.tfstate.id
}

output "lock_table_name" {
  value = aws_dynamodb_table.tflock.name
}
