# Bootstrap-purpose AWS provider — fetches the ExternalId secret needed by the
# main provider's AssumeRole, without depending on its own assume_role
# (chicken-and-egg avoidance). Only used when a cross-account terraformer role
# is configured (var.terraformer_role_arn / var.terraformer_external_id_secret).
provider "aws" {
  alias  = "bootstrap"
  region = "ap-northeast-2"
}

# Read the AssumeRole ExternalId only when both the role and the secret id are
# supplied. OSS / local runs leave these empty → no secret read, no assume_role.
data "aws_secretsmanager_secret_version" "terraformer_external_id" {
  count     = var.terraformer_role_arn != "" && var.terraformer_external_id_secret != "" ? 1 : 0
  provider  = aws.bootstrap
  secret_id = var.terraformer_external_id_secret
}

provider "aws" {
  region = "ap-northeast-2"

  # CI/CD (e.g. Atlantis) AssumeRole flow:
  #   runner identity → AssumeRole <terraformer_role_arn> (with ExternalId from
  #   Secrets Manager) → manage resources.
  # Account-specific values come from terraform.tfvars (git-ignored). Leaving
  # var.terraformer_role_arn empty disables the assume_role block (local creds).
  dynamic "assume_role" {
    for_each = var.terraformer_role_arn != "" ? [1] : []
    content {
      role_arn     = var.terraformer_role_arn
      external_id  = data.aws_secretsmanager_secret_version.terraformer_external_id[0].secret_string
      session_name = "callcenter-${var.env}"
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

# ADR-013: us-east-1 provider for CloudFront ACM + WAF v2 (CLOUDFRONT scope).
# Same AssumeRole chain as the primary region provider.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  dynamic "assume_role" {
    for_each = var.terraformer_role_arn != "" ? [1] : []
    content {
      role_arn     = var.terraformer_role_arn
      external_id  = data.aws_secretsmanager_secret_version.terraformer_external_id[0].secret_string
      session_name = "callcenter-${var.env}-use1"
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

# Slack webhook 은 ADR-009 에 따라 Secrets Manager 에 사전 등록되어 있다고
# 가정한다. 미등록 시 PR 머지 전 운영팀이 수동 등록:
#   aws secretsmanager create-secret \
#     --name callcenter-${var.env}-slack-webhook \
#     --secret-string "https://hooks.slack.com/services/..."
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

# ADR-013: HITL UI = CloudFront + VPC Origin → Private ALB.
# - acm_certificate_arn_us_east_1 / callback_domain 은 인증서 발급 후 주입.
# - 미주입 시점에는 ALB / ECS / Cognito 까지만 stand-up 되고 CloudFront 는 count=0.
module "hitl_ui" {
  source = "../../modules/hitl-ui"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  env                = var.env
  vpc_id             = module.shared.vpc_id
  private_subnet_ids = module.shared.private_subnet_ids
  ddb_consult_arn    = module.storage.ddb_consult_arn
  bucket_masked_arn  = module.storage.bucket_masked_arn
  bucket_raw_arn     = module.storage.bucket_raw_arn
  kms_ddb_arn        = module.storage.kms_ddb_arn
  kms_masked_arn     = module.storage.kms_masked_arn
  kms_raw_arn        = module.storage.kms_raw_arn

  # ACM / domain / image — account-specific, injected via terraform.tfvars.
  # When empty, the HITL UI stays in skeleton state (no listener / ECS / CloudFront).
  acm_certificate_arn           = var.hitl_acm_certificate_arn
  acm_certificate_arn_us_east_1 = var.hitl_acm_certificate_arn_us_east_1
  callback_domain               = var.hitl_callback_domain
  image_tag                     = var.hitl_image_tag
}
