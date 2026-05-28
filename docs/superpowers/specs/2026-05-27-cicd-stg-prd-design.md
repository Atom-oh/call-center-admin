# stg/prd env + 운영 런북 명세서 (PR10)

- **작성일**: 2026-05-27
- **저자**: project owner
- **범위**: Phase 1 PR10 — stg/prd 환경 복제 + 4종 운영 런북 + E2E smoke script
- **선행 의존**: PR1~PR9 머지
- **자율 실행 범위**: 환경 디렉토리 + 런북 문서 + smoke 스크립트 + test. **제외**: stg/prd backend bucket 생성, stg/prd apply, OIDC role 생성

## 1. 목표

- dev 환경 완료 후 stg/prd 로 동일 모듈 배포 (env 변수만 다름)
- 운영 인시던트 대응 절차를 4종 런북으로 명문화 (Slack 알람 → 런북 즉시 매칭 가능)
- E2E smoke 스크립트가 dev/stg/prd 모두에서 동작

## 2. stg/prd 환경 정의

dev 의 모든 module 을 동일하게 호출. workspace 분리는 backend tfstate key 로 처리.

### 2.1 디렉토리 구조

```
infra/envs/
├── dev/   (기존, 그대로)
├── stg/   (신규)
│   ├── backend.tf      key = "envs/stg/terraform.tfstate"
│   ├── main.tf         dev/main.tf 와 동일 module 호출, var.env = "stg"
│   ├── outputs.tf      dev/outputs.tf 와 동일
│   └── variables.tf    env default = "stg"
└── prd/   (신규)
    ├── backend.tf      key = "envs/prd/terraform.tfstate"
    ├── main.tf         동일 module 호출, var.env = "prd"
    ├── outputs.tf      동일
    └── variables.tf    env default = "prd"
```

### 2.2 환경별 차이 (현 시점)

| 항목 | dev | stg | prd |
|---|---|---|---|
| `env` 변수 | "dev" | "stg" | "prd" |
| backend key | envs/dev/... | envs/stg/... | envs/prd/... |
| Slack webhook | callcenter-dev-slack-webhook | callcenter-stg-slack-webhook | callcenter-prd-slack-webhook |
| HITL ALB FQDN | hitl.callcenter-dev.kakaopay.internal | hitl.callcenter-stg.kakaopay.internal | hitl.callcenter-prd.kakaopay.internal |
| Cognito domain prefix | callcenter-dev-hitl | callcenter-stg-hitl | callcenter-prd-hitl |

prd 의 ECS desired_count / RPM 한도 / HA 옵션은 PR-prd-hardening (별도 트랙) 에서 변경. **본 PR 은 dev 구조 1:1 복제만**.

## 3. 운영 런북 4종

각 런북은 다음 섹션을 필수 포함:
1. **증상** — 알람 / 메트릭 / 사용자 보고로 어떻게 감지되는가
2. **진단** — 어떤 로그 / 메트릭 / 쿼리를 확인하는가
3. **즉시 대응 (10분 안)** — 인시던트 완화
4. **영구 해결 (1~3일)** — 재발 방지
5. **회복 후 / 회귀 원인 분석**

### 3.1 `docs/runbooks/bedrock-throttling.md`

- 알람: `callcenter-{env}-bedrock-throttle` (classify Lambda Errors > 10/min)
- 즉시 대응: SFN execution 일시 중단 + Bedrock RPM 한도 임시 상향 요청
- 영구 해결: Provisioned Throughput 신청 또는 global CRIS routing 분석

### 3.2 `docs/runbooks/hitl-backlog.md`

- 알람: `callcenter-{env}-hitl-backlog` (60min 지속 > 100)
- 즉시 대응: HITL 검토 인력 추가 투입 / threshold 임시 0.85 → 0.75 상향
- 영구 해결: 골든셋 라벨 추가 + 프롬프트 v1.1 release

### 3.3 `docs/runbooks/prompt-rollback.md`

- 증상: 골든셋 정확도 -2%p 회귀 (CI eval-prompt fail)
- 즉시 대응: `PROMPT_VERSION` 이전 버전으로 rollback (`src/prompts/v<N-1>` 사용)
- 영구 해결: bisect — 어떤 룰 변경이 정확도 손실 유발

### 3.4 `docs/runbooks/pii-mask-failure.md`

- 증상: `pii.maskApplied` 메트릭 급감 OR Bedrock 응답의 reason 에 PII 누설 (cloudtrail 감사 검토)
- 즉시 대응: 정규식 패턴 재검토 + Layer-3 persist sweep 강화
- 영구 해결: Phase 2 진입 검토 (SageMaker Async + Qwen PII service)

## 4. ADR Decision 보존

본 PR 은 새 코드 거의 없음 — env 디렉토리 복제 + 문서. ADR 영향 0. 다만 다음 invariant 는 test 로 가드:

- 모든 env 디렉토리가 **동일 module set** 을 호출 (drift 없음)
- backend.tf 의 tfstate key 가 환경별로 분리 (충돌 0)
- env 변수의 default 가 디렉토리명과 일치

## 5. E2E smoke 스크립트

`scripts/e2e_smoke.py`:
- raw S3 에 STT JSON 업로드 → 60s 대기 → SFN 실행 결과 확인 → DDB row 확인 → Athena count 확인
- `--env dev|stg|prd` 인자
- AWS credential 은 caller 환경에서 (스크립트는 boto3 default chain)
- **본 PR 의 자율 실행 단계에서는 코드만 작성**, 실제 호출 없음

## 6. 테스트 매트릭스

### 6.1 `tests/integration/test_env_layout.py`

| Test | 검증 대상 |
|---|---|
| `test_dev_stg_prd_all_have_required_files` | 3 env 각각 backend.tf / main.tf / outputs.tf / variables.tf |
| `test_backend_keys_are_environment_separated` | backend key 가 envs/{env}/... 형식, 충돌 없음 |
| `test_env_variable_default_matches_directory_name` | variables.tf 의 env default 가 stg/prd 와 일치 |
| `test_main_tf_calls_same_modules_across_envs` | shared/storage/classify_pipeline/analytics/observability/hitl_ui 7 module 모두 호출 |
| `test_outputs_are_consistent_across_envs` | 모든 env 의 outputs.tf 가 동일 set |

### 6.2 `tests/integration/test_runbooks.py`

| Test | 검증 대상 |
|---|---|
| `test_four_required_runbooks_exist` | 4종 런북 파일 존재 |
| `test_each_runbook_has_required_sections` | 증상 / 진단 / 즉시 대응 / 영구 해결 / 회복 후 섹션 |
| `test_runbooks_reference_alarm_names` | bedrock-throttling 은 callcenter-{env}-bedrock-throttle, hitl-backlog 은 callcenter-{env}-hitl-backlog 참조 |
| `test_e2e_smoke_script_exists` | scripts/e2e_smoke.py 존재 + main 함수 + --env 인자 처리 |

## 7. 미해결 / 후속

- prd 의 ECS desired_count / Lambda reserved concurrency 등 hardening — 별도 트랙
- GitHub Actions OIDC role (각 env 별 callcenter-ci-{env}) — 사내 IAM 트랙
- E2E smoke 의 CI 자동 실행 — Atlantis post-apply hook 검토
