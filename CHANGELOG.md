# Changelog

<a href="#english"><img src="https://img.shields.io/badge/lang-English-blue.svg" alt="English"></a>
<a href="#korean"><img src="https://img.shields.io/badge/lang-한국어-red.svg" alt="Korean"></a>

All notable changes to **call-center-admin** are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

<a id="english"></a>

# English

## [Unreleased]

### Changed
- **PR Review model**: `.github/workflows/pr-review.yml` bumped from Claude Opus 4.7 → **Opus 4.8** (`global.anthropic.claude-opus-4-8`). Production classify / verify Lambda still pin Opus 4.7 / Sonnet 4.6 — that change requires ADR-010 update + golden-set regression re-evaluation, tracked separately.

### Added
- **GitHub Actions branch workflow** (`.github/workflows/`): `pr-review.yml` runs Claude Opus 4.8 on Bedrock against every PR and posts a structured review comment (filters out generated taxonomy artifacts + Terraform build dirs, caps diff at 3000 lines). `ci.yml` runs ruff + mypy + pytest with coverage + terraform fmt/validate + tflint + tfsec, with path filters that scope work to changed areas. (Terraform plan/apply was initially handled by GitHub Actions workflows but later migrated to **Atlantis** — see the Atlantis migration entry below; `terraform-plan.yml`/`terraform-apply.yml` no longer exist.)
- `.github/pull_request_template.md` enforcing the project's checklist (pytest baseline, ruff, mypy, terraform validate, Mermaid for ADRs, impact callouts).
- `docs/operations/github-actions-setup.md`: one-time OIDC provider creation, 3 IAM role trust policies (pr-review / tf-plan / tf-apply-{dev,stg,prd}), GitHub environment protection rules, branch protection rule, troubleshooting matrix.
- `tests/structure/test-github-actions.sh` harness checks (4 workflows + PR template + setup docs, including a negative assertion that `terraform-plan` never runs `apply`).
- Claude Code project scaffold via `/project-init:init-project`: root `CLAUDE.md`, 9 module `CLAUDE.md` files (`src/lib/`, `src/lambdas/{pii_guard,classify,verify,persist}/`, `src/prompts/`, `tests/`, `infra/`), `.claude/` (settings.json with permission allow/deny, 4 hooks, 4 skills, 3 commands, 2 agents), `docs/architecture.md` (bilingual, ASCII diagrams), ADR template with mandatory Mermaid diagram requirement, runbook template, `docs/onboarding.md`, `.mcp.json`, `.env.example`, `.editorconfig`, bilingual `README.md`, this `CHANGELOG.md`.

### Changed
- `CLAUDE.md` / `README.md` / `docs/onboarding.md`: branch workflow becomes mandatory (no direct `main` push). PR triggers automated Claude review + CI + plan. Merge to main triggers `dev` apply. stg/prd require manual workflow_dispatch + environment reviewer approval.
- All workflows now target **self-hosted runner labels** (aws-fsi-demo convention): `pr-review.yml` → `call-center-admin-claude-arm`, `ci.yml` → `call-center-admin-arm`, `terraform-{plan,apply}.yml` → `call-center-admin-x86`. `docs/operations/github-actions-setup.md` §2.5 adds the runner setup procedure (EC2 + IAM instance profile + GitHub runner registration + per-runner pre-install matrix). `pr-review.yml` no longer eagerly `npm install -g`s the CLI; it checks for `claude` and falls back to install only if the pre-install drifted.

### Phase 1 progress (PR1 – PR10 + follow-ups complete)
- **PR1**: project bootstrap + `src/lib/taxonomy.py` xlsx → 213-node taxonomy parser + `scripts/parse_taxonomy.py` CLI + 8 tests
- **PR2**: Terraform `shared` + `storage` modules (VPC, 8 VPC endpoints, KMS×4, S3×4, DynamoDB+3 GSIs+streams+TTL+PITR, SQS DLQ×2) + dev env wiring + remote state backend
- **PR3**: PII Guard Lambda + `src/lib/pii_regex.py` (regex with Luhn for cards, Korean-text boundary handling) + 9 tests
- **PR4**: Classify Lambda (Bedrock Opus 4.7) + `lib/prompts.py` two-breakpoint cache + `lib/output_schema.py` (trust-boundary hardening: top-level dict guard, bool confidence rejection, level bounds check, markdown fence) + golden set scaffold + `scripts/eval_prompt.py` + per-Lambda staging-dir Terraform packaging pattern + 11 tests
- **PR5**: Verify Lambda (Bedrock Sonnet 4.6 cross-verify, agreement-based HITL routing) + `lib/metrics.py` EMF emitter (exception-isolated) + 5 tests
- **PR6**: Persist Lambda (DDB put_item with `ConditionalCheckFailedException → silent skip`, optional Firehose, output PII sweep) + Step Functions Express ASL (8 states) + EventBridge S3 trigger + 9 tests + 1 integration test
- **PR7**: `analytics` module (Glue + Firehose Parquet + Athena workgroup + QuickSight datasets) + `docs/runbooks/quicksight-setup.md`
- **PR8**: HITL UI — `src/hitl_ui/` Streamlit app (review queue / search / compliance pages) + `infra/modules/hitl-ui/` (Fargate + internal ALB + Cognito); ALB `authenticate-cognito` with ES256 JWT signature verification (ADR-011)
- **PR9**: `observability` module — EMF metrics + CloudWatch dashboard + 5 alarms + SNS → Slack relay Lambda
- **PR10**: stg/prd environments + 5 runbooks + E2E smoke (`scripts/e2e_smoke.py`)
- **Migration**: Terraform plan/apply moved from GitHub Actions to **Atlantis** (ADR-009); `atlantis.yaml` per-env projects, `docs/operations/atlantis-setup.md`
- **ADR-013**: HITL UI fronted by CloudFront + VPC Origin + WAF (viewer cert us-east-1, origin cert ap-northeast-2)
- **ADR-014**: removed unsupported `temperature` from Bedrock calls (Opus 4.7 ValidationException); `eval_prompt.py --runs N` label-variance harness
- **ADR-011 follow-up**: HITL review queue first-write-wins optimistic lock (`ConditionExpression` + `AlreadyProcessedError`)
- **ADR-012**: HITL audit log 5-year retention (전자금융거래법 §22)
- **ADR-002 follow-up**: optional default-OFF `cache_warmer` Lambda + EventBridge cron to keep the prompt cache warm
- **Tooling/OSS**: ruff pinned to `==0.15.15` (formatter reproducibility); account-specific values moved to git-ignored `terraform.tfvars` / `backend.hcl`; PR-review model bumped to Opus 4.8

### Documentation
- Design spec at `docs/superpowers/specs/2026-05-22-callcenter-stt-classification-design.md` (model-agnostic InferenceAdapter, MLOps continuous-learning roadmap, 3-layer PII guard, ADR mandate)
- Phase 1 plan (`2026-05-22-phase1-callcenter-classification.md`) covers 10 PRs through prd cutover
- Phase 3 plan (`2026-05-22-phase3-mlops-continuous-learning.md`) covers 9 ML-PRs entry-conditioned on ~500 HITL labels accumulated
- `STATUS.md` autonomous-execution report covering PR1–PR6 with all decisions worth reviewing on wake-up

### Pending (intentional defer)
- Phase 3 MLOps (`continuous-learning` module: SageMaker Pipelines + Model Registry + Endpoint + KLUE-BERT cascade) — entry-conditioned on ~500 accumulated HITL labels and GPU/ML infra (ADR-001)
- `terraform apply` (dev/stg/prd) — runs through Atlantis after user approval; gated on compliance check for Raw STT external transmission and Bedrock quota allocation
- Operator setup: ACM certs, Slack webhook secret, Cognito users/groups, HITL UI container image to ECR

---

<a id="korean"></a>

# 한국어

## [Unreleased]

### 변경됨
- **PR Review 모델**: `.github/workflows/pr-review.yml` 의 Bedrock 모델 ID 를 Opus 4.7 → **Opus 4.8** (`global.anthropic.claude-opus-4-8`) 로 변경. production classify / verify Lambda 의 Opus 4.7 / Sonnet 4.6 은 그대로 (ADR-010 갱신 + 골든셋 재평가 후 별도 PR 로 처리).

### 추가됨
- **GitHub Actions 브랜치 워크플로우** (`.github/workflows/`): `pr-review.yml` 가 매 PR마다 Claude Opus 4.8 (Bedrock 호스팅) 으로 변경 사항 리뷰 후 구조화된 코멘트 게시 (생성된 taxonomy 산출물 + Terraform build dir 필터, diff 3000줄 cap). `ci.yml` 이 ruff + mypy + pytest(+coverage) + terraform fmt/validate + tflint + tfsec 실행, 변경 영역 path filter 적용. (Terraform plan/apply 은 초기에 GitHub Actions 워크플로우로 처리했으나 이후 **Atlantis** 로 이관 — 아래 Atlantis 이관 항목 참조; `terraform-plan.yml`/`terraform-apply.yml` 은 더 이상 존재하지 않음.)
- `.github/pull_request_template.md` — 프로젝트 체크리스트 (pytest baseline, ruff, mypy, terraform validate, ADR Mermaid 의무, 영향도 callout).
- `docs/operations/github-actions-setup.md` — 1회성 OIDC provider 생성, 3개 IAM role (pr-review / tf-plan / tf-apply-{dev,stg,prd}) trust policy, GitHub environment 보호 룰, branch protection 룰, troubleshooting 매트릭스.
- `tests/structure/test-github-actions.sh` harness 검증 (워크플로우 4종 + PR template + setup docs, `terraform-plan` 이 `apply` 호출 안 하는 negative 어설션 포함).
- `/project-init:init-project` 로 Claude Code 프로젝트 스캐폴드 생성: 루트 `CLAUDE.md`, 모듈 `CLAUDE.md` 9개 (`src/lib/`, `src/lambdas/{pii_guard,classify,verify,persist}/`, `src/prompts/`, `tests/`, `infra/`), `.claude/` (allow/deny 권한 정책의 settings.json, hook 4종, skill 4종, command 3종, agent 2종), `docs/architecture.md` (이중언어, ASCII 다이어그램), Mermaid 다이어그램 필수 규칙 명시된 ADR 템플릿, 런북 템플릿, `docs/onboarding.md`, `.mcp.json`, `.env.example`, `.editorconfig`, 이중언어 `README.md`, 본 `CHANGELOG.md`.

### 변경됨
- `CLAUDE.md` / `README.md` / `docs/onboarding.md` — 브랜치 워크플로우 의무화 (main 직접 push 금지). PR이 자동 Claude 리뷰 + CI + plan 트리거. main 머지 시 `dev` apply. stg/prd 는 workflow_dispatch + environment reviewer 승인.
- 모든 워크플로우가 **self-hosted runner 라벨** 사용 (aws-fsi-demo 컨벤션): `pr-review.yml` → `call-center-admin-claude-arm`, `ci.yml` → `call-center-admin-arm`, `terraform-{plan,apply}.yml` → `call-center-admin-x86`. `docs/operations/github-actions-setup.md` §2.5 에 러너 셋업 절차 (EC2 + IAM Instance Profile + GitHub runner 등록 + 러너별 pre-install 매트릭스) 추가. `pr-review.yml` 은 `npm install -g` 를 매번 실행하지 않고 pre-install 된 `claude` CLI 가 있는지 체크 후 fallback 만 수행.

### Phase 1 진행 상황 (PR1 ~ PR10 + 후속 완료)
- **PR1**: 프로젝트 부트스트랩 + `src/lib/taxonomy.py` xlsx → 213 노드 분류 파서 + `scripts/parse_taxonomy.py` CLI + 8 테스트
- **PR2**: Terraform `shared` + `storage` 모듈 (VPC, VPC endpoint 8개, KMS ×4, S3 ×4, DynamoDB+3 GSI+streams+TTL+PITR, SQS DLQ ×2) + dev 환경 wiring + remote state backend
- **PR3**: PII Guard Lambda + `src/lib/pii_regex.py` (카드용 Luhn 정규식, 한국어 텍스트 boundary 처리) + 9 테스트
- **PR4**: Classify Lambda (Bedrock Opus 4.7) + `lib/prompts.py` 2개 cache breakpoint + `lib/output_schema.py` (trust-boundary 강화: top-level dict 가드, bool confidence 거부, level 범위 체크, 마크다운 fence) + 골든셋 scaffold + `scripts/eval_prompt.py` + per-Lambda staging-dir Terraform 패키징 패턴 + 11 테스트
- **PR5**: Verify Lambda (Bedrock Sonnet 4.6 cross-verify, agreement 기반 HITL 라우팅) + `lib/metrics.py` EMF emitter (예외 격리) + 5 테스트
- **PR6**: Persist Lambda (DDB put_item with `ConditionalCheckFailedException → silent skip`, optional Firehose, 출력 PII sweep) + Step Functions Express ASL (8 state) + EventBridge S3 트리거 + 9 테스트 + 1 통합 테스트
- **PR7**: `analytics` 모듈 (Glue + Firehose Parquet + Athena workgroup + QuickSight 데이터셋) + `docs/runbooks/quicksight-setup.md`
- **PR8**: HITL UI — `src/hitl_ui/` Streamlit 앱 (검수 큐 / 검색 / 컴플라이언스 페이지) + `infra/modules/hitl-ui/` (Fargate + 내부 ALB + Cognito); ALB `authenticate-cognito` + ES256 JWT 서명 검증 (ADR-011)
- **PR9**: `observability` 모듈 — EMF 메트릭 + CloudWatch 대시보드 + 알람 5종 + SNS → Slack relay Lambda
- **PR10**: stg/prd 환경 + 런북 5종 + E2E smoke (`scripts/e2e_smoke.py`)
- **이관**: Terraform plan/apply 을 GitHub Actions → **Atlantis** 로 이관 (ADR-009); `atlantis.yaml` env 별 프로젝트, `docs/operations/atlantis-setup.md`
- **ADR-013**: HITL UI 를 CloudFront + VPC Origin + WAF 로 fronting (viewer 인증서 us-east-1, origin 인증서 ap-northeast-2)
- **ADR-014**: Bedrock 호출에서 미지원 `temperature` 제거 (Opus 4.7 ValidationException); `eval_prompt.py --runs N` 라벨 변동성 하니스
- **ADR-011 후속**: HITL 검수 큐 선착순 낙관적 락 (`ConditionExpression` + `AlreadyProcessedError`)
- **ADR-012**: HITL 감사 로그 5년 보존 (전자금융거래법 §22)
- **ADR-002 후속**: 옵션 default-OFF `cache_warmer` Lambda + EventBridge cron 으로 프롬프트 캐시 워밍
- **툴링/OSS**: ruff `==0.15.15` 정확 핀 (formatter 재현성); 계정 특정 값을 git-ignored `terraform.tfvars` / `backend.hcl` 로 분리; PR-review 모델 Opus 4.8 로 상향

### 문서
- 설계 스펙 `docs/superpowers/specs/2026-05-22-callcenter-stt-classification-design.md` (model-agnostic InferenceAdapter, MLOps 자동 학습 로드맵, 3중 PII 가드, ADR 의무)
- Phase 1 계획 (`2026-05-22-phase1-callcenter-classification.md`) — prd 출시까지의 10 PR 분해
- Phase 3 계획 (`2026-05-22-phase3-mlops-continuous-learning.md`) — HITL 500건 누적 진입 조건의 9 ML-PR
- `STATUS.md` 자율 실행 결과 (PR1–PR6 완료) + 사용자 검토 필요 결정 사항

### 보류 (의도적 deferral)
- Phase 3 MLOps (`continuous-learning` 모듈: SageMaker Pipelines + Model Registry + Endpoint + KLUE-BERT cascade) — HITL 라벨 ~500건 누적 + GPU/ML 인프라 진입 조건 (ADR-001)
- `terraform apply` (dev/stg/prd) — Atlantis 경유, 사용자 승인 후 진행; Raw STT 외부 송신 컴플라이언스 + Bedrock 쿼터 확보 게이트
- 운영팀 셋업: ACM 인증서, Slack webhook secret, Cognito user/group, HITL UI 컨테이너 이미지 ECR push

---

[Unreleased]: https://github.com/Atom-oh/call-center-admin/compare/HEAD...main
