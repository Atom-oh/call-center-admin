# stg env — identical module set as dev. Differences live in var.env only.
# Spec: docs/superpowers/specs/2026-05-27-cicd-stg-prd-design.md §2

provider "aws" {
  alias  = "bootstrap"
  region = "ap-northeast-2"
}

data "aws_secretsmanager_secret_version" "terraformer_external_id" {
  provider  = aws.bootstrap
  secret_id = "<EXTERNAL_ID_SECRET>"
}

provider "aws" {
  region = "ap-northeast-2"

  dynamic "assume_role" {
    for_each = var.terraformer_role_arn != "" ? [1] : []
    content {
      role_arn     = var.terraformer_role_arn
      external_id  = data.aws_secretsmanager_secret_version.terraformer_external_id.secret_string
      session_name = "atlantis-callcenter-${var.env}"
    }
  }

  default_tags {
    tags = {
      project    = "callcenter-classification"
      env        = var.env
      managed-by = "terraform"
    }
  }
}

module "shared" {
  source = "../../modules/shared"
  env    = var.env
}

module "storage" {
  source = "../../modules/storage"
  env    = var.env
  vpc_id = module.shared.vpc_id
}

module "analytics" {
  source               = "../../modules/analytics"
  env                  = var.env
  bucket_analytics_arn = module.storage.bucket_analytics_arn
  bucket_analytics_id  = module.storage.bucket_analytics_id
  kms_analytics_arn    = module.storage.kms_analytics_arn
}

module "classify_pipeline" {
  source = "../../modules/classify-pipeline"

  env                = var.env
  vpc_id             = module.shared.vpc_id
  private_subnet_ids = module.shared.private_subnet_ids
  bucket_raw_arn     = module.storage.bucket_raw_arn
  bucket_masked_arn  = module.storage.bucket_masked_arn
  bucket_masked_id   = module.storage.bucket_masked_id
  kms_raw_arn        = module.storage.kms_raw_arn
  kms_masked_arn     = module.storage.kms_masked_arn
  ddb_consult_arn    = module.storage.ddb_consult_arn
  kms_ddb_arn        = module.storage.kms_ddb_arn
  classify_dlq_arn   = module.storage.classify_dlq_arn
  persist_dlq_arn    = module.storage.persist_dlq_arn
  firehose_name      = module.analytics.firehose_name
  firehose_arn       = module.analytics.firehose_arn
}

data "aws_secretsmanager_secret_version" "slack_webhook" {
  secret_id = "callcenter-${var.env}-slack-webhook"
}

module "observability" {
  source = "../../modules/observability"

  env                  = var.env
  slack_webhook_url    = data.aws_secretsmanager_secret_version.slack_webhook.secret_string
  sfn_arn              = module.classify_pipeline.sfn_arn
  classify_dlq_name    = "callcenter-${var.env}-classify-dlq"
  persist_dlq_name     = "callcenter-${var.env}-persist-dlq"
  lambda_classify_name = module.classify_pipeline.classify_name
  lambda_verify_name   = module.classify_pipeline.verify_name
  lambda_persist_name  = module.classify_pipeline.persist_name
  lambda_pii_name      = module.classify_pipeline.pii_guard_name
}

# hitl_ui module 은 PR8 머지 후 별도 follow-up 에서 추가.
