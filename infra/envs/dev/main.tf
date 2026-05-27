provider "aws" {
  region = "ap-northeast-2"

  # Atlantis 실행 흐름:
  #   Atlantis pod (IRSA: AtlantisIRSARole, account 180294183052)
  #     → AssumeRole DemoPlatformTerraformer (atomoh-main account)
  #     → 리소스 생성/수정/삭제
  #
  # DemoPlatformTerraformer 는 callcenter Lambda/SFN/Bedrock/Glue/Firehose/Athena/S3/DDB/KMS/EventBridge/SQS 등
  # 모든 리소스 권한을 보유한다 (AWS-Demo-Platform 의 accounts.yaml + IAM 모듈 관리).
  #
  # 로컬 dev 환경 (또는 GA OIDC 백업 호출) 에서는 var.terraformer_role_arn 을 빈 문자열로
  # override 하면 assume_role 블록이 비활성화된다.
  dynamic "assume_role" {
    for_each = var.terraformer_role_arn != "" ? [1] : []
    content {
      role_arn     = var.terraformer_role_arn
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
