# Project Context

## Overview

**call-center-admin** — 카카오페이 콜센터 상담 STT(녹취 → 텍스트) 결과를 Amazon Bedrock(Claude Opus 4.7 + Sonnet 4.6 cross-verify)로 자동 분류(대/중/소 18 / 64 / 131 노드)하고, 운영팀 HITL 검수와 분석팀 BI 대시보드까지 닫힌 폐쇄 루프를 6주 안에 출시하는 시스템. 정확도 우선, 비동기 처리, S3 트리거 기반.

설계서: `docs/superpowers/specs/2026-05-22-callcenter-stt-classification-design.md`
구현 계획: `docs/superpowers/plans/` (Phase 1 6주, Phase 3 MLOps 4-6주)
현재 진행: PR1~PR6 완료 (코드/Terraform 정의 + 42 단위 테스트). `STATUS.md` 참조.

## Tech Stack

- **Language**: Python 3.12 (`from __future__ import annotations` 일관, PEP 604 unions)
- **LLM**: Amazon Bedrock (Anthropic Claude Opus 4.7 primary, Sonnet 4.6 verify, ap-northeast-2)
- **AWS**: Lambda (4종), Step Functions Express, EventBridge, S3, DynamoDB (+3 GSI, streams, TTL, PITR), KMS CMK ×4, SQS DLQ ×2, VPC + 8 Interface VPC Endpoints
- **IaC**: Terraform 1.9+ (workspace 분리: dev/stg/prd; remote state S3 + DDB lock)
- **Dependencies**: `boto3`, `botocore`, `openpyxl`, `pydantic`
- **Dev tools**: `pytest`, `moto` (AWS mock), `ruff`, `mypy --strict`, `pytest-cov`
- **Deferred (Phase 3)**: SageMaker Pipelines + Model Registry + Endpoint + KLUE-BERT fine-tune

## Project Structure

```
docs/                       — 설계·계획·런북·아키텍처
  superpowers/specs/        — 본 시스템 설계서 (단일 소스)
  superpowers/plans/        — Phase 1, Phase 3 구현 계획서
  decisions/                — ADR (architecture decision records)
  runbooks/                 — 운영 런북
.claude/                    — Claude Code hooks, skills, commands, agents
  hooks/                    — PreToolUse / PostToolUse / SessionStart 스크립트
  skills/                   — code-review, refactor, release, sync-docs
  commands/                 — /review, /test-all, /deploy
  agents/                   — code-reviewer, security-auditor
infra/                      — Terraform 정의
  shared-state/             — tfstate S3 bucket + DDB lock (한 번만 apply)
  modules/
    shared/                 — VPC, 3 private subnets, 8 VPC endpoints
    storage/                — KMS×4, S3×4, DynamoDB+3GSIs, SQS DLQ×2
    classify-pipeline/      — Lambda×4 + SFN Express + EventBridge
  envs/dev/                 — dev 환경 root module
src/
  lambdas/
    pii_guard/              — regex-based hard PII masking (raw → masked S3)
    classify/               — Bedrock Opus 4.7 분류 호출 (대/중/소 + confidence + reason)
    verify/                 — Bedrock Sonnet 4.6 cross-verify, 합의/불일치 분기
    persist/                — DDB put_item + (옵션) Firehose Parquet + EMF 메트릭
  lib/                      — 공유 모듈 (taxonomy, pii_regex, prompts, output_schema,
                              bedrock_client, inference_adapter, persistence, metrics)
  prompts/v1.0/             — system_rules.md + taxonomy_tree.{json,md} (생성 산출물)
tests/
  unit/                     — 42개 pytest (모든 lib + lambda handler 커버)
  integration/              — SFN ASL 정적 구조 검증
  golden/                   — 골든셋 scaffold (5행, g001만 real label)
scripts/
  parse_taxonomy.py         — xlsx → src/prompts/v1.0/ 산출물 재생성 CLI
  eval_prompt.py            — 골든셋에서 Bedrock 실호출하여 대/중/소 정확도 평가
tools/prompts/              — 실험·디버깅용 일회성 프롬프트
```

## Conventions

### Python
- **3.12 target** (`requires-python = ">=3.12"` in `pyproject.toml`). 로컬 테스트는 Python 3.9에서도 동작하도록 `from __future__ import annotations` 일관 사용.
- **Ruff**: `select = ["E", "F", "I", "B", "UP", "N", "SIM", "RUF"]`. `ignore = ["E501"]`. `target-version = "py312"`, `line-length = 100`.
- **Mypy**: `strict = true`. `# type: ignore` 코멘트는 마지막 수단이고 사유 코멘트 동반.
- **데이터 클래스 우선** (Pydantic은 외부 경계 직렬화/검증에만). `Protocol`로 인터페이스 추상화.
- **모듈 docstring** 첫 줄 한 줄 요약, 그 다음 빈 줄 후 상세. 한국어/영어 혼용 OK.

### Lambda packaging
- **Per-Lambda staging-dir 패턴**: `infra/modules/classify-pipeline/main.tf`의 `data "external" "<name>_stage"`가 빌드 시 필요한 모듈만 `build/<name>/`에 복사 → `data "archive_file"`로 zip. 새 Lambda 추가 시 동일 패턴을 따른다.
- 각 handler `sys.path.insert(0, str(Path(__file__).parent.parent.parent))` 로 `/var/task/` 루트에서 `lib/` import. **TODO(phase2)**: Lambda Layer로 일괄 정리.

### Terraform
- 1.9+, AWS provider `~> 5.70`, `archive ~> 2.4`, `external ~> 2.3`.
- 모듈 input/output 인터페이스 명시. **사용 시점**별 그룹 코멘트 (`# PR3 (PII Guard) — actively used`, `# Reserved for PR7 (Firehose Parquet)` 등).
- KMS는 데이터 클래스별 분리 (raw / masked / analytics / ddb 각 1 CMK).
- 모든 S3는 versioning + SSE-KMS + PAB. lifecycle 룰에는 반드시 `filter {}` 명시 (provider 6.x 호환).
- DDB attribute 명은 한국어(`category_대code`) 허용. 그러나 **DDB index 명은 ASCII 만 허용**(`[a-zA-Z0-9_.-]+`) — 한글 attribute 를 가리키는 GSI 는 romanize: `category-daecode-classifiedAt-index` (`대` → `daecode`).

### 분류 코드 식별자
- xlsx 원본의 코드 문자열을 **글자 하나 변형 없이** 그대로 사용. `NONEY`(MONEY 오타), `PAYNENT`(PAYMENT 오타) 등은 시스템 식별자이므로 의도적 보존. 코드 안에 "fix" 하지 말 것.

### PII
- **3중 가드**: (1) Step Functions 첫 단계 `pii_guard` Lambda가 정규식으로 하드 PII (계좌·카드·주민·휴대폰) 마스킹, (2) 프롬프트 R5 룰이 LLM에게 출력 PII 인용 금지 지시, (3) `persist` Lambda가 DDB 쓰기 전 `reason`/`alternativesConsidered`에 동일 정규식 재적용.
- 한글 인근 숫자에서 `\b` boundary가 작동하지 않으므로 `(?<!\d)/(?!\d)` 사용.

### 테스트
- **TDD**: 실패하는 테스트 먼저 → 구현 → 통과.
- **moto**로 AWS mock (S3, DDB). Bedrock은 `MagicMock + patch("lib.bedrock_client.boto3.client")`.
- module-level adapter 캐시 우회를 위해 verify/persist 핸들러 테스트는 `sys.modules.pop("lambdas.<name>.handler", None)` fixture 사용.
- 골든셋 평가 (`scripts/eval_prompt.py`)는 Bedrock 실호출이므로 CI에서는 OIDC 통한 dev 호출, PR마다 -2%p 회귀 시 fail.

### Git / 브랜치 전략 (필수)
- **main 직접 push 금지**. 모든 변경은 feature branch → PR → 리뷰 → 머지 흐름.
- 브랜치 명명: `feat/...`, `fix/...`, `docs/...`, `refactor/...`, `test/...`, `chore/...`, `ci/...`
- PR이 올라오면 자동 실행 (.github/workflows/):
  1. **AI 리뷰** (`pr-review.yml`) — Claude Opus 4.8 on Bedrock 이 CLAUDE.md 룰에 따라 변경 리뷰 후 코멘트
  2. **CI** (`ci.yml`) — ruff + mypy + pytest + terraform fmt/validate + tfsec + 분류 트리 산출물 stale 검사
  3. **Atlantis** — `infra/**` 변경 시 [Atlantis](https://atlantis.atomai.click) 가 PR 에 `plan` 결과 코멘트 게시.
     PR 코멘트로 `atlantis plan` / `atlantis apply` 재실행/적용. 설정: `atlantis.yaml`.
- main 머지 시: Atlantis apply 는 PR 코멘트에서 끝나므로 머지 후 별도 액션 없음.
  stg/prd 는 `infra/envs/{stg,prd}/` 가 생성되면 `atlantis.yaml` 의 해당 프로젝트 블록 주석을 해제.
- Conventional commit 메시지: `feat(scope): ...`, `fix(scope): ...`, `docs(scope): ...`, `test(scope): ...`, `refactor(scope): ...`, `chore(scope): ...`, `ci(scope): ...`
- 메시지 본문의 Co-Authored-By 라인은 `scripts/install-hooks.sh` 가 설치하는 `commit-msg` hook 이 자동 제거.
- 셋업 절차: `docs/operations/atlantis-setup.md` (Atlantis IRSA trust, branch protection).
  기존 GitHub Actions OIDC 셋업 절차(`docs/operations/github-actions-setup.md` §1, §2) 는 `pr-review.yml` / `ci.yml` 의 OIDC 사용을 위해 여전히 유효합니다.

## Key Commands

```bash
# 가상환경 + 개발 의존성 설치
python -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"

# 전체 테스트
pytest                              # 42 단위·통합 테스트, coverage 포함
pytest --no-cov                     # coverage 없이 빠르게
pytest tests/unit/test_taxonomy.py -v   # 특정 파일만

# 정적 검사
ruff check src tests scripts
ruff format src tests scripts
mypy src

# Terraform (dev)
terraform fmt -recursive infra/
terraform -chdir=infra/envs/dev init -backend=false -reconfigure
terraform -chdir=infra/envs/dev validate
# 실제 적용은 사용자 승인 후:
# terraform -chdir=infra/shared-state apply         (한 번만)
# terraform -chdir=infra/envs/dev apply

# 분류 트리 재생성 (xlsx 변경 시)
python scripts/parse_taxonomy.py --xlsx 상담어시스트_AWS전달자료.xlsx

# 골든셋 평가 (Bedrock 실호출 — dev 환경 apply 후)
python scripts/eval_prompt.py --skip-tbd

# 운영 smoke test (dev apply 후)
aws s3 cp /tmp/smoke.json s3://kakaopay-callcenter-dev-stt-raw/YYYY/MM/DD/smoke.json
```

---

## Auto-Sync Rules

Rules below are applied automatically after Plan mode exit and on major code changes.

### Post-Plan Mode Actions
After exiting Plan mode (`/plan`), before starting implementation:

1. **Architecture decision made** → Update `docs/architecture.md`
2. **Technical choice/trade-off made** → Create `docs/decisions/ADR-NNN-title.md`
3. **New module added** → Create `CLAUDE.md` in that module directory
4. **Operational procedure defined** → Create runbook in `docs/runbooks/`
5. **Changes needed in this file** → Update relevant sections above

### Code Change Sync Rules
- New directory under `src/` → Must create `CLAUDE.md` alongside
- New Lambda handler under `src/lambdas/` → Must create `CLAUDE.md` in that lambda dir + add `data "external" "<name>_stage"` block in `infra/modules/classify-pipeline/main.tf` + add IAM/log group/lambda function blocks
- Bedrock prompt template changed → bump `PROMPT_VERSION` in `src/lib/prompts.py` + new directory `src/prompts/v<N>.<M>/`
- Taxonomy regenerated → commit both `taxonomy_tree.json` and `taxonomy_tree.md`
- Infrastructure changed → Update `docs/architecture.md` Infrastructure section + regenerate `terraform validate`
- DDB schema/GSI changed → Update `infra/modules/storage/main.tf` AND `src/lib/persistence.py:build_ddb_item` together (drift = correctness bug)

### ADR Numbering
Find the highest number in `docs/decisions/ADR-*.md` and increment by 1.
Format: `ADR-NNN-concise-title.md`.

### ADR Mermaid Requirement
**모든 ADR은 Mermaid 다이어그램으로 아키텍처 흐름을 시각화해야 한다.** Prose만 있는 ADR은 미완성으로 간주. ADR 템플릿(`docs/decisions/.template.md`)의 `## Architecture Flow` 섹션을 비워두지 말고, 결정이 영향을 주는 흐름에 맞는 다이어그램 타입을 선택해 채운다:
- 데이터/요청 흐름 → ```mermaid``` 블록의 `flowchart LR` 또는 `flowchart TB`
- 시간 순서의 단계 호출 → `sequenceDiagram`
- 상태 전이 (예: HITL 상태 머신) → `stateDiagram-v2`
- 컴포넌트 의존성 → `flowchart` + subgraph

