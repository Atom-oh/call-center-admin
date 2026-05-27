# Bootstrap-purpose AWS provider — uses Atlantis IRSA directly (no
# assume_role) to fetch the ExternalId secret needed by the main provider.
# Avoids the chicken-and-egg of provider depending on its own data source.
provider "aws" {
  alias  = "bootstrap"
  region = "ap-northeast-2"
}

data "aws_secretsmanager_secret_version" "terraformer_external_id" {
  provider  = aws.bootstrap
  secret_id = "/demo-platform/external-ids/atomoh-main/terraformer"
}

provider "aws" {
  region = "ap-northeast-2"

  # Atlantis 실행 흐름:
  #   Atlantis pod (IRSA: AtlantisIRSARole, account 180294183052)
  #     → AssumeRole DemoPlatformTerraformer (with ExternalId from Secrets Manager)
  #     → 리소스 생성/수정/삭제
  #
  # DemoPlatformTerraformer 는 callcenter Lambda/SFN/Bedrock/Glue/Firehose/Athena/S3/DDB/KMS/EventBridge/SQS 등
  # 모든 리소스 권한을 보유한다 (AWS-Demo-Platform 의 accounts.yaml + IAM 모듈 관리).
  # Trust policy 가 ExternalId condition 을 강제하므로, Secrets Manager 의
  # `/demo-platform/external-ids/atomoh-main/terraformer` 에서 값을 가져와 전달한다.
  #
  # 로컬 dev 환경 (또는 GA OIDC 백업 호출) 에서는 var.terraformer_role_arn 을 빈 문자열로
  # override 하면 assume_role 블록이 비활성화된다.
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

# Slack webhook 은 Secrets Manager 에 사전 등록되어 있다는 가정.
# 미등록 환경에서는 placeholder secret 을 생성하거나 module 호출을
# count=0 로 비활성화해야 한다.
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
