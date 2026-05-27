# `infra/` — Terraform IaC

## Role

AWS 리소스 정의. dev/stg/prd 환경별 workspace를 사용하며, remote state는 별도 `shared-state/` 에서 한 번만 부트스트랩한 S3 버킷 + DDB lock 테이블을 공유한다.

## Structure

```
infra/
├── shared-state/        — tfstate 버킷 + DDB lock (1회만 apply)
├── modules/
│   ├── shared/          — VPC, subnets, VPC endpoints
│   ├── storage/         — KMS, S3, DynamoDB, SQS DLQ
│   ├── classify-pipeline/ — Lambda ×4 + SFN Express + EventBridge
│   ├── analytics/       — (PR7) Glue + Firehose + Athena + QuickSight
│   ├── hitl-ui/         — (PR8) Fargate + ALB + Cognito
│   └── observability/   — (PR9) CW dashboards + alarms + Slack relay
└── envs/
    ├── dev/             — 현재 active. backend.tf로 tfstate key=envs/dev/...
    ├── stg/             — (PR10)
    └── prd/             — (PR10)
```

## Rules

### Provider 버전
- `aws ~> 5.70`
- `archive ~> 2.4`
- `external ~> 2.3`
- Terraform 1.9+

### 모듈 인터페이스
- 각 모듈은 `variables.tf` / `main.tf` / `outputs.tf` 3종 분리
- 변수는 **사용 시점별 그룹 코멘트**:
  ```hcl
  # PR3 (PII Guard) — actively used
  variable "bucket_raw_arn" { type = string }
  # Reserved for PR4+ (classify/verify/persist VPC config)
  variable "vpc_id" { type = string }
  ```

### KMS 데이터 클래스 분리
- 4개 CMK: `raw`, `masked`, `analytics`, `ddb`
- 각 S3 버킷은 자신의 데이터 클래스 CMK 사용
- ml 버킷은 analytics CMK 공유 (의도적 — 분석 데이터와 access pattern 동일)
- 각 Lambda IAM은 필요한 CMK ARN 만 scope (allow `*` 금지)

### S3 lifecycle
- 모든 S3 버킷: versioning + SSE-KMS + bucket_key + PAB ON
- `aws_s3_bucket_lifecycle_configuration` 의 `rule` 은 **반드시 `filter {}` 명시** (AWS provider 6.x 호환)
- raw: Glacier IR @ 90d → Deep Archive @ 365d, non-current 90d/365d 동일
- masked: expire @ 365d, non-current 30d
- 새 버킷 추가 시 lifecycle 정책 함께 정의

### DynamoDB
- attribute 명에 한국어 허용 (`category_대code` 등)
- DDB index 명은 ASCII 만 허용 (`[a-zA-Z0-9_.-]+`). 한글 attribute (`category_대code`) 를 가리키는 GSI 는 romanize 한 이름 사용: `category-daecode-classifiedAt-index` (`대` → `daecode`).
- TTL=`ttlEpoch` (epoch seconds)
- streams `NEW_AND_OLD_IMAGES`
- PITR ON

### Lambda 패키징
- per-Lambda staging-dir 패턴 (`data "external" "<name>_stage"` + `data "archive_file"`)
- 새 Lambda 추가 시 PR5의 verify Lambda 블록을 copy & rename
- `${path.module}/build/<name>/` 디렉토리는 `.gitignore` 의 `infra/modules/*/build/` 로 제외

### SFN Express
- 단일 state machine `callcenter-<env>-classify`
- 8 states: PiiGuard, Classify, ConfidenceBranch (Choice), Verify, MarkAutoHigh (Pass), Persist, SendToClassifyDlq, SendToPersistDlq
- ResultPath/OutputPath: `Payload.$ = "$"` + `ResultSelector { result.$ = "$.Payload" }` + `OutputPath = "$.result"` 패턴 모든 Task state에 일관
- Retry: classify 5회 (ThrottlingException/ServiceUnavailable), 그 외 3회
- Catch: classify→ClassifyDlq, persist→PersistDlq

### EventBridge
- S3 raw 버킷에 `aws_s3_bucket_notification { eventbridge = true }`
- 별도 `aws_cloudwatch_event_rule` 가 패턴 매칭 + `aws_cloudwatch_event_target` 가 SFN 실행
- input_transformer로 `{"rawBucket": ..., "rawKey": ...}` 프로젝션

### 명령어
- `terraform fmt -recursive infra/` — PR 전 필수
- `terraform -chdir=infra/envs/dev init -backend=false -reconfigure` — provider 갱신 후
- `terraform -chdir=infra/envs/dev validate` — 코드 변경 후 항상 실행
- `terraform apply` 는 **사용자 명시 승인 후에만**. 자율 모드에서는 금지.
