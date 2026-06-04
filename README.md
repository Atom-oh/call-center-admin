# call-center-admin

[![License](https://img.shields.io/badge/License-Internal-lightgrey)](https://github.com/Atom-oh/call-center-admin)
[![Python](https://img.shields.io/badge/python-3.12-blue)](https://www.python.org/)
[![Terraform](https://img.shields.io/badge/terraform-1.9+-purple)](https://www.terraform.io/)

<a href="#english"><img src="https://img.shields.io/badge/lang-English-blue.svg" alt="English"></a>
<a href="#korean"><img src="https://img.shields.io/badge/lang-한국어-red.svg" alt="Korean"></a>

> **Automated STT classification pipeline for KakaoPay call center transcripts** — Amazon Bedrock 기반 콜센터 STT 자동 분류 시스템

---

<a id="english"></a>

# English

## Overview

Asynchronous, event-driven classification pipeline that consumes STT (speech-to-text) call transcripts from Amazon S3 and assigns three-level taxonomy labels (대 / 중 / 소, 18 / 64 / 131 nodes) using Amazon Bedrock — Claude Opus 4.7 as primary classifier and Sonnet 4.6 as cross-verifier. Disagreement and low-confidence cases route to a human-in-the-loop (HITL) queue, while results land in both DynamoDB (operational) and S3 Parquet (analytics).

Phase 1 (PR1–PR10 plus follow-ups) is complete: classification pipeline, analytics, HITL UI, observability, and Atlantis-based CI/CD, with 14 ADRs and 156 tests. Phase 3 (MLOps continuous-learning pipeline) remains.

## Features

- **Step Functions Express** orchestration with PII guard → classify → confidence branch → verify → persist
- **3-layer PII guard**: regex pre-filter + system-prompt rule R5 + output sweep at persist
- **Two-breakpoint prompt cache**: separates stable rules from regeneratable taxonomy tree; an optional, default-OFF cache-warmer Lambda keeps the cache warm (ADR-002)
- **Pluggable inference**: `InferenceAdapter` Protocol lets a Phase-3 KLUE-BERT cascade slot in without changing SFN definition
- **xlsx-preserved code identifiers**: original taxonomy typos (`NONEY`, `PAYNENT`) are system identifiers, kept verbatim
- **Idempotent persistence**: DDB `ConditionalCheckFailedException` on `promptVersion` drift silently skips, keeping DLQ as a true-error signal
- **Per-Lambda staging-dir packaging**: each Lambda zip contains only its required modules, minimizing cold-start size and attack surface
- **HITL review UI**: Streamlit on Fargate behind CloudFront + VPC Origin + Cognito (ADR-011/013); first-write-wins optimistic lock and a 5-year audit log (ADR-012)
- **Deterministic Bedrock calls**: Opus 4.7 rejects `temperature`/`top_p`/`top_k`, so `inferenceConfig` carries only `maxTokens`; label stability is measured via `eval_prompt.py --runs N` (ADR-014)

## Prerequisites

- Python 3.12+
- Terraform 1.9+
- AWS CLI v2 (for any apply/operate workflow)

## Installation

```bash
git clone git@github.com:Atom-oh/call-center-admin.git
cd call-center-admin
python3 -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"
```

## Usage

```bash
# Run the test suite (156 tests)
pytest --no-cov

# Static checks
ruff check src tests scripts
mypy src

# Terraform validate (offline, no AWS calls)
terraform fmt -recursive -check infra/
terraform -chdir=infra/envs/dev init -backend=false -reconfigure
terraform -chdir=infra/envs/dev validate

# Regenerate the taxonomy tree from the source xlsx
python3 scripts/parse_taxonomy.py --xlsx 상담어시스트_AWS전달자료.xlsx

# Evaluate the prompt against the golden set (calls Bedrock; requires AWS credentials)
python3 scripts/eval_prompt.py --skip-tbd
```

For dev `terraform apply`, see `docs/onboarding.md` and `STATUS.md`. Apply is gated on compliance approval and Bedrock quota allocation.

## Project Structure

```
docs/
  superpowers/specs/      design spec (single source of truth)
  superpowers/plans/      Phase 1 (10 PRs) + Phase 3 (9 ML-PRs) plans
  decisions/              ADRs (Mermaid diagram required)
  runbooks/               operational runbooks
  architecture.md         bilingual architecture overview
.claude/                  Claude Code hooks, skills, commands, agents
infra/                    Terraform (shared / storage / classify-pipeline / analytics / hitl-ui / observability)
src/
  lambdas/{pii_guard,classify,verify,persist}/   4 pipeline Lambda handlers
  lambdas/cache_warmer/   optional prompt-cache warmer (default-OFF, ADR-002)
  lib/                    shared pure modules (taxonomy, prompts, pii_regex, etc.)
  prompts/v1.0/           system rules + taxonomy tree artifacts
  hitl_ui/                HITL review Streamlit app (streamlit_app + hitl_lib/ + pages/)
tests/
  unit/                   pytest unit tests (lib + lambda handlers + hitl_lib)
  integration/            SFN / observability / hitl-ui / cache_warmer static-structure tests
  golden/                 hand-labeled samples scaffold
scripts/                  CLI helpers (parse_taxonomy.py, eval_prompt.py, e2e_smoke.py)
```

## Testing

```bash
pytest                              # all 156 tests, coverage included
pytest --no-cov                     # fast feedback
pytest tests/unit/test_taxonomy.py -v
```

See `tests/CLAUDE.md` for TDD conventions, Lambda handler test patterns, and golden-set guidance.

## Contributing

This is an internal project. The contribution workflow is:

1. Read `CLAUDE.md` for conventions (Python 3.12, ruff, mypy strict, Lambda packaging, KMS scoping, etc.)
2. Pick a remaining PR from `docs/superpowers/plans/2026-05-22-phase1-callcenter-classification.md`
3. **Create a feature branch (`feat/...`, `fix/...`)** — never push directly to `main`
4. Follow `superpowers:subagent-driven-development` skill: implementer → spec reviewer → code-quality reviewer
5. Every ADR you create must include a Mermaid architecture flow diagram (`docs/decisions/.template.md`)
6. Commit with conventional prefix: `feat(scope): …`, `fix(scope): …`, etc.
7. Tests must pass; `terraform fmt -check` and `validate` must be clean.
8. Open a PR. The following automation runs automatically:
   - **AI Review** (`pr-review.yml`) — Claude Opus 4.8 on Bedrock posts a structured review comment
   - **CI** (`ci.yml`) — ruff + mypy + pytest + terraform fmt/validate + tfsec + taxonomy-artifact stale check
   - **Atlantis** — `infra/**` changes get a `terraform plan` comment from the Atlantis server; re-run with `atlantis plan` / apply with `atlantis apply` in PR comments (`atlantis.yaml`)
9. After a human reviewer approves and CI passes, merge to `main`. Atlantis apply happens from the PR comment, so no post-merge action is needed. `stg`/`prd` projects activate by uncommenting their blocks in `atlantis.yaml`.

Setup: `docs/operations/atlantis-setup.md` (Atlantis IRSA trust, branch protection). The GitHub Actions OIDC setup (`docs/operations/github-actions-setup.md`) remains valid for `pr-review.yml` / `ci.yml`.

## License

Internal — KakaoPay Co., Ltd.

## Contact

- Maintainer: Atom-oh ([@Atom-oh](https://github.com/Atom-oh))
- Repository: [github.com/Atom-oh/call-center-admin](https://github.com/Atom-oh/call-center-admin)

---

<a id="korean"></a>

# 한국어

## 개요

Amazon S3에 업로드된 STT(녹음 → 텍스트) 결과를 비동기·이벤트 드리븐 파이프라인으로 받아 Amazon Bedrock (Claude Opus 4.7 primary + Sonnet 4.6 cross-verify)로 3단계 분류 라벨(대 / 중 / 소, 18 / 64 / 131 노드)을 부여한다. 신뢰도 낮거나 모델 간 불일치 케이스는 HITL 큐로 라우팅되며, 결과는 DynamoDB(운영용)과 S3 Parquet(분석용)에 함께 적재된다.

Phase 1 (PR1–PR10 + 후속) 완료: 분류 파이프라인, analytics, HITL UI, observability, Atlantis 기반 CI/CD — 14 ADR, 156 테스트. Phase 3 (MLOps 자동 학습) 은 보류 중.

## 특징

- **Step Functions Express** 로 PII 가드 → 분류 → confidence 분기 → 검증 → 적재 단계 시각적 오케스트레이션
- **3중 PII 가드**: 정규식 사전 마스킹 + 시스템 프롬프트 R5 룰 + persist 단계 출력 sweep
- **2개 cache breakpoint**: 안정된 룰 블록과 재생성 가능한 분류 트리 블록 분리로 캐시 적중 극대화; 옵션(default-OFF) cache-warmer Lambda 가 캐시 워밍 (ADR-002)
- **Pluggable inference**: `InferenceAdapter` Protocol로 Phase 3의 KLUE-BERT cascade가 SFN 변경 없이 끼어 들어감
- **xlsx 원본 코드 보존**: 분류 코드의 `NONEY`/`PAYNENT` 오타도 시스템 식별자이므로 그대로 유지
- **Idempotent persistence**: DDB `ConditionalCheckFailedException` 이 `promptVersion` drift일 때 silent skip — DLQ는 진짜 오류 신호로 유지
- **Per-Lambda staging-dir 패키징**: 각 Lambda zip에 필요한 모듈만 포함, 콜드 스타트와 attack surface 최소화
- **HITL 검수 UI**: CloudFront + VPC Origin + Cognito 뒤의 Fargate Streamlit (ADR-011/013); 선착순 낙관적 락 + 5년 감사 로그 (ADR-012)
- **결정론적 Bedrock 호출**: Opus 4.7 은 `temperature`/`top_p`/`top_k` 거부 → `inferenceConfig` 에 `maxTokens` 만; 라벨 안정성은 `eval_prompt.py --runs N` 으로 측정 (ADR-014)

## 사전 요구사항

- Python 3.12+
- Terraform 1.9+
- AWS CLI v2 (apply/운영 워크플로우용)

## 설치

```bash
git clone git@github.com:Atom-oh/call-center-admin.git
cd call-center-admin
python3 -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"
```

## 사용법

```bash
# 테스트 스위트 실행 (156개)
pytest --no-cov

# 정적 검사
ruff check src tests scripts
mypy src

# Terraform validate (오프라인, AWS 호출 없음)
terraform fmt -recursive -check infra/
terraform -chdir=infra/envs/dev init -backend=false -reconfigure
terraform -chdir=infra/envs/dev validate

# xlsx 원본에서 분류 트리 재생성
python3 scripts/parse_taxonomy.py --xlsx 상담어시스트_AWS전달자료.xlsx

# 골든셋 평가 (Bedrock 실호출, AWS 자격 필요)
python3 scripts/eval_prompt.py --skip-tbd
```

dev 환경 `terraform apply` 는 `docs/onboarding.md` 와 `STATUS.md` 참고. 컴플라이언스 승인 + Bedrock 쿼터 확보 후 진행.

## 프로젝트 구조

```
docs/
  superpowers/specs/      설계 spec (단일 소스)
  superpowers/plans/      Phase 1 (10 PR) + Phase 3 (9 ML-PR) 계획서
  decisions/              ADR (Mermaid 다이어그램 필수)
  runbooks/               운영 런북
  architecture.md         이중 언어 아키텍처 개요
.claude/                  Claude Code hooks, skills, commands, agents
infra/                    Terraform (shared / storage / classify-pipeline / analytics / hitl-ui / observability)
src/
  lambdas/{pii_guard,classify,verify,persist}/   4개 파이프라인 Lambda handler
  lambdas/cache_warmer/   옵션 프롬프트 캐시 워머 (default-OFF, ADR-002)
  lib/                    공유 pure 모듈 (taxonomy, prompts, pii_regex 등)
  prompts/v1.0/           시스템 룰 + 분류 트리 산출물
  hitl_ui/                HITL 검수 Streamlit 앱 (streamlit_app + hitl_lib/ + pages/)
tests/
  unit/                   pytest 단위 테스트 (lib + lambda handler + hitl_lib)
  integration/            SFN / observability / hitl-ui / cache_warmer 정적 구조 테스트
  golden/                 손 라벨링된 골든셋 scaffold
scripts/                  CLI 헬퍼 (parse_taxonomy.py, eval_prompt.py, e2e_smoke.py)
```

## 테스트

```bash
pytest                              # 전체 156개, coverage 포함
pytest --no-cov                     # 빠른 피드백
pytest tests/unit/test_taxonomy.py -v
```

TDD 컨벤션, Lambda handler 테스트 패턴, 골든셋 가이드는 `tests/CLAUDE.md` 참고.

## 기여하기

본 프로젝트는 내부 프로젝트입니다. 기여 워크플로우:

1. `CLAUDE.md` 의 컨벤션 (Python 3.12, ruff, mypy strict, Lambda 패키징, KMS scoping 등) 숙지
2. `docs/superpowers/plans/2026-05-22-phase1-callcenter-classification.md` 에서 잔여 PR 선택
3. **feature branch 생성** (`feat/...`, `fix/...`) — `main` 직접 push 금지
4. `superpowers:subagent-driven-development` 스킬 사용: implementer → spec reviewer → code-quality reviewer
5. 새 ADR 작성 시 **Mermaid 아키텍처 흐름도 필수** (`docs/decisions/.template.md` 참고)
6. Conventional commit prefix 사용: `feat(scope): …`, `fix(scope): …` 등
7. 테스트 통과 + `terraform fmt -check` + `validate` clean 필수
8. PR 올리면 자동 실행:
   - **AI 리뷰** (`pr-review.yml`) — Claude Opus 4.8 (Bedrock) 가 CLAUDE.md 룰에 맞춰 리뷰 코멘트 게시
   - **CI** (`ci.yml`) — ruff + mypy + pytest + terraform fmt/validate + tfsec + 분류 트리 산출물 stale 검사
   - **Atlantis** — `infra/**` 변경 시 Atlantis 서버가 `terraform plan` 결과를 PR 코멘트로 게시; PR 코멘트의 `atlantis plan` / `atlantis apply` 로 재실행·적용 (`atlantis.yaml`)
9. 사람 리뷰어 승인 + CI 통과 후 `main` 머지. Atlantis apply 는 PR 코멘트에서 끝나므로 머지 후 별도 액션 없음. `stg`/`prd` 는 `atlantis.yaml` 의 해당 블록 주석 해제로 활성화.

셋업: `docs/operations/atlantis-setup.md` (Atlantis IRSA trust, branch protection). GitHub Actions OIDC 셋업(`docs/operations/github-actions-setup.md`) 은 `pr-review.yml` / `ci.yml` 용으로 여전히 유효.

## 라이선스

Internal — 카카오페이 주식회사

## 연락처

- Maintainer: Atom-oh ([@Atom-oh](https://github.com/Atom-oh))
- Repository: [github.com/Atom-oh/call-center-admin](https://github.com/Atom-oh/call-center-admin)
