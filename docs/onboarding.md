# Onboarding — call-center-admin

신규 엔지니어가 본 프로젝트를 받아 1시간 안에 첫 테스트 실행까지 도달하기 위한 가이드.

## Prerequisites

| 도구 | 버전 | 용도 |
|------|------|------|
| Python | 3.12+ | 본 프로젝트 런타임 타깃. 로컬 3.9도 `from __future__ import annotations` 덕분에 동작하지만, CI/Lambda는 3.12 |
| Terraform | 1.9+ | IaC. AWS provider `~> 5.70` |
| AWS CLI | v2 | dev/stg/prd 적용·검증 시 사용 (apply 권한은 사용자별로 제한) |
| git | 2.40+ | 본 프로젝트는 main 브랜치에 직접 작업 |
| pip / venv | latest | dev 의존성 설치 |

## 1. Clone & Install

```bash
git clone git@github.com:Atom-oh/call-center-admin.git
cd call-center-admin

python3 -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
```

## 2. Run Tests

```bash
pytest --no-cov                                  # 42 baseline 단위/통합 테스트
pytest tests/unit/test_taxonomy.py -v --no-cov   # 단일 파일
```

기대 결과: `42 passed, 0 failed`. 실패한다면 `pip install --user 'moto[s3,dynamodb]>=5.0'` 또는 `python3 -m pip install -e ".[dev]"` 재설치 후 재시도.

## 3. Static checks

```bash
ruff check src tests scripts
ruff format --check src tests scripts
mypy src
```

## 4. Terraform validation (no apply)

```bash
terraform fmt -recursive -check infra/
terraform -chdir=infra/envs/dev init -backend=false -reconfigure
terraform -chdir=infra/envs/dev validate
```

기대 결과: `Success! The configuration is valid.` 처음 init 시 provider 다운로드로 1-2분 소요.

## 5. Read the design

1. `docs/superpowers/specs/2026-05-22-callcenter-stt-classification-design.md` — 본 시스템 단일 소스 (모델 선택, MLOps 로드맵, 권한 매트릭스, 비용 추정 등 모두 포함)
2. `docs/architecture.md` — 컴포넌트 + 데이터 흐름 + 핵심 설계 결정 요약
3. `docs/superpowers/plans/2026-05-22-phase1-callcenter-classification.md` — Phase 1 10 PR 분해
4. `CLAUDE.md` — 코딩 규칙, 명명 규칙, Auto-Sync 규칙
5. `STATUS.md` — 자율 실행으로 PR1~PR6 완료된 현재 상태

## 6. First contribution (suggested)

PR7-10이 미진행 상태. 다음 중 하나를 골라 시작:
- PR7 Analytics: Glue + Firehose Parquet + Athena + QuickSight runbook
- PR8 HITL UI: Streamlit on Fargate + Cognito + internal ALB
- PR9 Observability: 5 알람 + Slack relay Lambda + CloudWatch dashboard
- PR10 CI/CD + 런북 4종 + stg/prd 환경 + E2E smoke

각 PR은 plan 파일의 step-by-step 가이드를 그대로 따르면 됨. `superpowers:subagent-driven-development` 스킬 사용 권장.

### Branch / PR 워크플로우

본 저장소는 **main 직접 push 금지**. 모든 변경은:

```bash
git checkout -b feat/<short-topic>
# ... 작업 + 테스트 + commit ...
git push -u origin feat/<short-topic>
gh pr create --base main --fill   # 또는 GitHub UI
```

PR 올라가면 자동으로:
1. **AI Review** (`.github/workflows/pr-review.yml`) — Claude (Bedrock Opus 4.7) 가 CLAUDE.md 룰 기준으로 리뷰 → PR 코멘트
2. **CI** (`.github/workflows/ci.yml`) — ruff + mypy + pytest + terraform fmt/validate + tfsec
3. **Terraform Plan** (`.github/workflows/terraform-plan.yml`) — `infra/**` 변경 시 `dev` plan → PR 코멘트

머지 후:
- **Terraform Apply** (`.github/workflows/terraform-apply.yml`) — `infra/**` 변경 시 `dev` 자동 apply
- stg/prd 는 GitHub UI 에서 `workflow_dispatch` + environment 보호 룰 reviewer 승인 필요

1회성 OIDC role / GitHub environment 셋업은 `docs/operations/github-actions-setup.md` 참고.

## 7. AWS access (선택)

dev 환경 apply 권한이 필요한 경우:
- AWS Account: <kakaopay-callcenter-dev>
- IAM Role: `callcenter-dev-developer` (assume via SSO)
- Region: `ap-northeast-2`

apply 권한 없이도 모든 코드/Terraform/테스트 작업 가능. 실제 apply는 인프라 담당자가 검토 후 수행.

## 8. Communications

- 설계 변경 / 결정 → `docs/decisions/ADR-NNN-*.md` (Mermaid 다이어그램 필수)
- 운영 절차 → `docs/runbooks/*.md`
- 일상 회고 / 결정 컨텍스트 → 별도 문서 또는 PR 메시지 본문

## 9. Troubleshooting

| 증상 | 가능 원인 | 조치 |
|------|----------|------|
| `pytest: command not found` | venv 미활성 | `source .venv/bin/activate` |
| moto SSL 오류 | moto 버전 너무 낮음 | `pip install --upgrade 'moto[s3,dynamodb]>=5.0'` |
| `terraform validate` 실패: providers | provider lock 파일 손상 | `terraform init -backend=false -reconfigure` |
| `python scripts/parse_taxonomy.py` FileNotFoundError | xlsx 파일명이 NFD vs NFC | `ls *.xlsx` 로 발견 후 `--xlsx "$(ls *.xlsx)"` |
| 한국어 column 명 (`category_대code`) CloudWatch Insights 에서 안 보임 | 인용 부호 누락 | `"category_대code"` 로 quote |
