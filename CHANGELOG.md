# Changelog

[![English](https://img.shields.io/badge/Language-English-blue)](#english) [![한국어](https://img.shields.io/badge/언어-한국어-red)](#한국어)

All notable changes to **call-center-admin** are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

# English

## [Unreleased]

### Added
- Claude Code project scaffold via `/project-init:init-project`: root `CLAUDE.md`, 9 module `CLAUDE.md` files (`src/lib/`, `src/lambdas/{pii_guard,classify,verify,persist}/`, `src/prompts/`, `tests/`, `infra/`), `.claude/` (settings.json with permission allow/deny, 4 hooks, 4 skills, 3 commands, 2 agents), `docs/architecture.md` (bilingual, ASCII diagrams), ADR template with mandatory Mermaid diagram requirement, runbook template, `docs/onboarding.md`, `.mcp.json`, `.env.example`, `.editorconfig`, bilingual `README.md`, this `CHANGELOG.md`.

### Phase 1 progress (PR1 – PR6 complete)
- **PR1**: project bootstrap + `src/lib/taxonomy.py` xlsx → 213-node taxonomy parser + `scripts/parse_taxonomy.py` CLI + 8 tests
- **PR2**: Terraform `shared` + `storage` modules (VPC, 8 VPC endpoints, KMS×4, S3×4, DynamoDB+3 GSIs+streams+TTL+PITR, SQS DLQ×2) + dev env wiring + remote state backend
- **PR3**: PII Guard Lambda + `src/lib/pii_regex.py` (regex with Luhn for cards, Korean-text boundary handling) + 9 tests
- **PR4**: Classify Lambda (Bedrock Opus 4.7) + `lib/prompts.py` two-breakpoint cache + `lib/output_schema.py` (trust-boundary hardening: top-level dict guard, bool confidence rejection, level bounds check, markdown fence) + golden set scaffold + `scripts/eval_prompt.py` + per-Lambda staging-dir Terraform packaging pattern + 11 tests
- **PR5**: Verify Lambda (Bedrock Sonnet 4.6 cross-verify, agreement-based HITL routing) + `lib/metrics.py` EMF emitter (exception-isolated) + 5 tests
- **PR6**: Persist Lambda (DDB put_item with `ConditionalCheckFailedException → silent skip`, optional Firehose, output PII sweep) + Step Functions Express ASL (8 states) + EventBridge S3 trigger + 9 tests + 1 integration test

### Documentation
- Design spec at `docs/superpowers/specs/2026-05-22-callcenter-stt-classification-design.md` (model-agnostic InferenceAdapter, MLOps continuous-learning roadmap, 3-layer PII guard, ADR mandate)
- Phase 1 plan (`2026-05-22-phase1-callcenter-classification.md`) covers 10 PRs through prd cutover
- Phase 3 plan (`2026-05-22-phase3-mlops-continuous-learning.md`) covers 9 ML-PRs entry-conditioned on ~500 HITL labels accumulated
- `STATUS.md` autonomous-execution report covering PR1–PR6 with all decisions worth reviewing on wake-up

### Pending (intentional defer)
- PR7 Analytics (Glue + Firehose Parquet + Athena + QuickSight)
- PR8 HITL UI (Streamlit on Fargate + Cognito + internal ALB)
- PR9 Observability (5 alarms + Slack relay + CloudWatch dashboard)
- PR10 CI/CD + stg/prd environments + 4 runbooks + E2E smoke
- `terraform apply` — requires user approval, compliance check on Raw STT external transmission, and Bedrock quota allocation

---

# 한국어

## [Unreleased]

### 추가됨
- `/project-init:init-project` 로 Claude Code 프로젝트 스캐폴드 생성: 루트 `CLAUDE.md`, 모듈 `CLAUDE.md` 9개 (`src/lib/`, `src/lambdas/{pii_guard,classify,verify,persist}/`, `src/prompts/`, `tests/`, `infra/`), `.claude/` (allow/deny 권한 정책의 settings.json, hook 4종, skill 4종, command 3종, agent 2종), `docs/architecture.md` (이중언어, ASCII 다이어그램), Mermaid 다이어그램 필수 규칙 명시된 ADR 템플릿, 런북 템플릿, `docs/onboarding.md`, `.mcp.json`, `.env.example`, `.editorconfig`, 이중언어 `README.md`, 본 `CHANGELOG.md`.

### Phase 1 진행 상황 (PR1 ~ PR6 완료)
- **PR1**: 프로젝트 부트스트랩 + `src/lib/taxonomy.py` xlsx → 213 노드 분류 파서 + `scripts/parse_taxonomy.py` CLI + 8 테스트
- **PR2**: Terraform `shared` + `storage` 모듈 (VPC, VPC endpoint 8개, KMS ×4, S3 ×4, DynamoDB+3 GSI+streams+TTL+PITR, SQS DLQ ×2) + dev 환경 wiring + remote state backend
- **PR3**: PII Guard Lambda + `src/lib/pii_regex.py` (카드용 Luhn 정규식, 한국어 텍스트 boundary 처리) + 9 테스트
- **PR4**: Classify Lambda (Bedrock Opus 4.7) + `lib/prompts.py` 2개 cache breakpoint + `lib/output_schema.py` (trust-boundary 강화: top-level dict 가드, bool confidence 거부, level 범위 체크, 마크다운 fence) + 골든셋 scaffold + `scripts/eval_prompt.py` + per-Lambda staging-dir Terraform 패키징 패턴 + 11 테스트
- **PR5**: Verify Lambda (Bedrock Sonnet 4.6 cross-verify, agreement 기반 HITL 라우팅) + `lib/metrics.py` EMF emitter (예외 격리) + 5 테스트
- **PR6**: Persist Lambda (DDB put_item with `ConditionalCheckFailedException → silent skip`, optional Firehose, 출력 PII sweep) + Step Functions Express ASL (8 state) + EventBridge S3 트리거 + 9 테스트 + 1 통합 테스트

### 문서
- 설계 스펙 `docs/superpowers/specs/2026-05-22-callcenter-stt-classification-design.md` (model-agnostic InferenceAdapter, MLOps 자동 학습 로드맵, 3중 PII 가드, ADR 의무)
- Phase 1 계획 (`2026-05-22-phase1-callcenter-classification.md`) — prd 출시까지의 10 PR 분해
- Phase 3 계획 (`2026-05-22-phase3-mlops-continuous-learning.md`) — HITL 500건 누적 진입 조건의 9 ML-PR
- `STATUS.md` 자율 실행 결과 (PR1–PR6 완료) + 사용자 검토 필요 결정 사항

### 보류 (의도적 deferral)
- PR7 Analytics (Glue + Firehose Parquet + Athena + QuickSight)
- PR8 HITL UI (Streamlit on Fargate + Cognito + 내부 ALB)
- PR9 Observability (알람 5종 + Slack relay + CloudWatch 대시보드)
- PR10 CI/CD + stg/prd 환경 + 런북 4종 + E2E smoke
- `terraform apply` — 사용자 승인, Raw STT 외부 송신 컴플라이언스 확인, Bedrock 쿼터 확보 필요

---

[Unreleased]: https://github.com/Atom-oh/call-center-admin/compare/HEAD...main
