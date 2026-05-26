terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
}

locals {
  bucket_prefix = "kakaopay-callcenter-${var.env}"
}

# ---------- KMS keys per data class ----------
resource "aws_kms_key" "raw" {
  description             = "${var.env} raw STT bucket key"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}
resource "aws_kms_alias" "raw" {
  name          = "alias/callcenter-${var.env}-raw"
  target_key_id = aws_kms_key.raw.id
}

resource "aws_kms_key" "masked" {
  description             = "${var.env} masked STT + pipeline key"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}
resource "aws_kms_alias" "masked" {
  name          = "alias/callcenter-${var.env}-masked"
  target_key_id = aws_kms_key.masked.id
}

resource "aws_kms_key" "analytics" {
  description             = "${var.env} analytics parquet key"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}
resource "aws_kms_alias" "analytics" {
  name          = "alias/callcenter-${var.env}-analytics"
  target_key_id = aws_kms_key.analytics.id
}

resource "aws_kms_key" "ddb" {
  description             = "${var.env} DynamoDB key"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}
resource "aws_kms_alias" "ddb" {
  name          = "alias/callcenter-${var.env}-ddb"
  target_key_id = aws_kms_key.ddb.id
}

# ---------- S3 buckets ----------
resource "aws_s3_bucket" "raw" { bucket = "${local.bucket_prefix}-stt-raw" }
resource "aws_s3_bucket" "masked" { bucket = "${local.bucket_prefix}-stt-masked" }
resource "aws_s3_bucket" "analytics" { bucket = "${local.bucket_prefix}-analytics" }
resource "aws_s3_bucket" "ml" { bucket = "${local.bucket_prefix}-ml" }

locals {
  buckets = {
    raw       = { id = aws_s3_bucket.raw.id, kms = aws_kms_key.raw.arn }
    masked    = { id = aws_s3_bucket.masked.id, kms = aws_kms_key.masked.arn }
    analytics = { id = aws_s3_bucket.analytics.id, kms = aws_kms_key.analytics.arn }
    ml        = { id = aws_s3_bucket.ml.id, kms = aws_kms_key.analytics.arn }
  }
}

resource "aws_s3_bucket_versioning" "v" {
  for_each = local.buckets
  bucket   = each.value.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "enc" {
  for_each = local.buckets
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = each.value.kms
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "pab" {
  for_each                = local.buckets
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id
  rule {
    id     = "tiering"
    status = "Enabled"
    filter {} # apply to all objects (AWS provider 6.x requires explicit filter/prefix)
    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }
    transition {
      days          = 365
      storage_class = "DEEP_ARCHIVE"
    }
    noncurrent_version_transition {
      noncurrent_days = 90
      storage_class   = "GLACIER_IR"
    }
    noncurrent_version_expiration {
      noncurrent_days = 365
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "masked" {
  bucket = aws_s3_bucket.masked.id
  rule {
    id     = "delete-after-1y"
    status = "Enabled"
    filter {} # apply to all objects
    expiration { days = 365 }
    noncurrent_version_expiration {
      noncurrent_days = 30 # masked data has no audit need after current version expires
    }
  }
}

# ---------- DynamoDB ----------
resource "aws_dynamodb_table" "consult_results" {
  name             = "callcenter-${var.env}-consult-results"
  billing_mode     = "PAY_PER_REQUEST"
  hash_key         = "callId"
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  attribute {
    name = "callId"
    type = "S"
  }
  attribute {
    name = "agentId"
    type = "S"
  }
  attribute {
    name = "status"
    type = "S"
  }
  attribute {
    name = "category_대code"
    type = "S"
  }
  attribute {
    name = "classifiedAt"
    type = "S"
  }

  global_secondary_index {
    name            = "status-classifiedAt-index"
    hash_key        = "status"
    range_key       = "classifiedAt"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "agentId-classifiedAt-index"
    hash_key        = "agentId"
    range_key       = "classifiedAt"
    projection_type = "ALL"
  }

  global_secondary_index {
    # NOTE: index name aligned with attribute name (`category_대code`).
    # Renaming after first `terraform apply` requires DDB table replacement,
    # so fixed in PR2 before any apply. Plan/spec text uses the older
    # `category대code-...` form — the storage module is the source of truth.
    name            = "category_대code-classifiedAt-index"
    hash_key        = "category_대code"
    range_key       = "classifiedAt"
    projection_type = "ALL"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.ddb.arn
  }

  ttl {
    attribute_name = "ttlEpoch"
    enabled        = true
  }

  point_in_time_recovery { enabled = true }
}

# ---------- DLQs ----------
resource "aws_sqs_queue" "classify_dlq" {
  name                      = "callcenter-${var.env}-classify-dlq"
  message_retention_seconds = 1209600
  kms_master_key_id         = aws_kms_key.masked.arn
}

resource "aws_sqs_queue" "persist_dlq" {
  name                      = "callcenter-${var.env}-persist-dlq"
  message_retention_seconds = 1209600
  kms_master_key_id         = aws_kms_key.masked.arn
}
