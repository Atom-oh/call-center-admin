# Observability 시스템 명세서 (PR9)

- **작성일**: 2026-05-27
- **저자**: project owner
- **범위**: Phase 1 PR9 — 운영 가시성 + 알람 + Slack 통보
- **선행 의존**: PR1~PR6 머지 완료, ADR-001~010 채택
- **후속 의존**: PR8 HITL UI (`classification.hitlPending` 메트릭은 PR8 에서 본격 emit)

## 1. 목표

분류 파이프라인의 **실패 / 지연 / 회귀** 를 사람이 직접 로그를 뒤지지 않고 **5분 안에** 인지하도록 한다. 알람은 Slack 으로 직배달. CloudWatch 대시보드 1 개로 핵심 KPI 1 화면 요약.

**비목표 (out of scope)**:
- PagerDuty / Opsgenie 연동 (Phase 2)
- 분산 trace (X-Ray) — Lambda runtime 만 Phase 2 활성화
- 운영팀 RBAC for 대시보드 (PR10 IAM 분리 시 처리)

## 2. 시스템 컴포넌트

```
EMF stdout (Lambda)  ──┐
                       ├─►  CloudWatch Metrics  ──►  Metric Alarms ──►  SNS topic  ──►  Slack relay Lambda  ──►  Slack channel
AWS/Lambda Errors    ──┤                                                  │
AWS/States Failed    ──┤                                                  └──►  (PR10) PagerDuty subscription
AWS/SQS depth        ──┘
                                                                                    
                                                  Dashboard (6 widgets)
```

### 2.1 EMF 메트릭 (Lambda → stdout → CW Logs → CW Metrics 자동 수집)

| 메트릭 | namespace | dim | emit 위치 | 의미 |
|---|---|---|---|---|
| `pii.maskApplied` | `callcenter/classification` | env, pii_type | `pii_guard` handler | PII 마스킹 적중 횟수 (per-type) |
| `classify.invoked` | `callcenter/classification` | env, 대code | `classify` handler | LLM 호출 카운트 |
| `classify.confidence` | `callcenter/classification` | env, 대code | `classify` handler | 분류 confidence (분포 분석용) |
| `classification.verifyTriggered` | `callcenter/classification` | env, agreement | `verify` handler (기존) | Sonnet 교차 검증 결과 |
| `classification.processed` | `callcenter/classification` | env, 대code | `persist` handler (기존) | DDB write 성공 |
| `classification.skippedExisting` | `callcenter/classification` | env, 대code | `persist` handler (기존) | promptVersion conflict silent-skip |
| `classification.hitlPending` | `callcenter/classification` | env | (PR8) HITL UI | HITL 대기열 깊이 — PR9 알람 정의 |

### 2.2 알람 (CloudWatch Metric Alarm × 5)

| # | 이름 | 메트릭 | 조건 | 근거 |
|---|---|---|---|---|
| 1 | `sfn_failure` | `AWS/States/ExecutionsFailed` (SFN 차원) | sum >= 3 / 5분 | 단발 retry 통과, 지속 실패 차단 |
| 2 | `classify_dlq_backlog` | `AWS/SQS/ApproximateNumberOfMessagesVisible` (classify DLQ) | max > 10 / 1분 | DLQ 깊이 = Bedrock 회복 불가 |
| 3 | `persist_dlq_backlog` | 동일 (persist DLQ) | max > 10 / 1분 | DDB 회복 불가 |
| 4 | `bedrock_throttle` | `AWS/Lambda/Errors` (classify function) | sum > 10 / 1분 | retry 5 회 후 throttle 잔존 |
| 5 | `hitl_backlog` | `callcenter/classification/classification.hitlPending` | max > 100, 12 datapoints × 5 분 (= 60 분 지속) | 단발 spike 무시, 지속 적체 알람 |

### 2.3 대시보드 위젯 (6 개)

1. 분류 처리량 (1 시간 sum)
2. 평균 confidence (5 분 avg)
3. SFN 실행 결과 (Failed / Succeeded / TimedOut)
4. DLQ depth (classify-dlq, persist-dlq overlay)
5. Lambda Errors (4 functions overlay)
6. PII 마스킹 적중 (phone / rrn / account / card overlay)

### 2.4 Slack 통보

- SNS topic → Lambda 구독 (URL secret 노출 회피)
- Slack relay Lambda: Python 3.12 runtime, **stdlib 만** (urllib.request), Inline `archive_file` source
- Webhook URL: Secrets Manager `callcenter-{env}-slack-webhook` 에 사전 등록 → envs/{env}/main.tf 가 data source 로 읽어 sensitive 변수 전달
- 메시지 포맷: `:warning: *{AlarmName}*\n{NewStateReason}` (3500 chars 초과 시 truncate)
- 실패 시 stdout 로그 + return — SNS retry 큐 적체 방지

## 3. ADR Decision 보존 매트릭스 (필수 가드)

본 PR9 구현이 **반드시** 보존해야 하는 ADR 결정사항. 각 항목은 test case 로 가드된다.

| ADR | Decision | 본 PR9 의 영향 | 보존 방식 | 검증 test |
|---|---|---|---|---|
| ADR-001 Pluggable Adapter | InferenceAdapter Protocol | 영향 없음 (메트릭만 추가) | classify handler 의 LLM 호출 흐름 변경 0 | `test_classify_returns_structured_result` 회귀 유지 |
| ADR-002 Two-breakpoint cache | 2개 cachePoint 구조 | 영향 없음 | Bedrock 호출 변경 없음 | 기존 `test_prompts` 회귀 유지 |
| ADR-003 3-layer PII guard | regex + R5 + persist sweep | EMF 가 PII 누설 source 가 될 위험 | metric **value 만**, PII 텍스트는 dim/value 어디에도 X | `test_pii_metric_does_not_leak_text` |
| ADR-004 xlsx 코드 보존 | NONEY/PAYNENT 등 보존 | 대code dim 으로 사용 | "fix" 시도 없음 — 그대로 dim 값 | `test_classify_metric_uses_xlsx_code_verbatim` |
| ADR-005 staging-dir packaging | per-Lambda staging | Slack relay 는 별도 Lambda — 어떻게 패키징? | **별도 inline `archive_file`** (build/ 안에 zip) — pii_guard 등 영향 0 | `test_slack_relay_uses_inline_archive` |
| ADR-006 KMS 데이터 클래스 분리 | 4 CMK (raw/masked/analytics/ddb) | Slack relay Lambda 는 어떤 CMK 도 grant 받지 않음 | IAM policy 에 KMS Resource 0 | `test_slack_relay_iam_no_kms_grant` |
| ADR-007 SFN Express 8-state | 8 state 구조 | 알람이 SFN ARN dim 참조 | SFN ARN 변경 없음, 알람만 추가 | `test_sfn_failure_alarm_uses_state_machine_arn_dim` |
| ADR-008 한국어 attribute + ASCII GSI | DDB attribute 한국어 / index 명 ASCII | 대시보드/알람 차원에 한국어 OK | `대code` dim 사용 가능 (CW dim 에 unicode 허용) | `test_dashboard_uses_korean_dim_value_via_dim_name_or_avoids_it` |
| ADR-009 Atlantis | terraform plan/apply 위임 | Slack webhook secret 은 사전 등록 가정 | data "aws_secretsmanager_secret_version" 사용, 모듈은 secret 직접 생성 X | `test_observability_does_not_create_secret` |
| ADR-010 global Bedrock CRIS | global. prefix | 영향 없음 | classify Lambda 변경 0 (메트릭만 추가) | 기존 `test_classify_returns_structured_result` 회귀 유지 |

## 4. 명시적 보안/규정 가드

- **G1**: Slack webhook URL 은 Terraform state 에 평문으로 들어갈 수 있음 (sensitive=true 로 plan 출력은 redact). KMS 암호화 state backend 필수 (이미 PR2 에서 충족).
- **G2**: EMF 메트릭에 PII 텍스트 인용 금지. `pii.maskApplied` 는 count 만, text 는 0.
- **G3**: Slack relay Lambda 는 VPC 밖 (인터넷 outbound 필요). 다른 Lambda 와 분리.
- **G4**: 알람 trip 시 `NewStateReason` 에 dim 값이 포함될 수 있음. 한국어 attribute 값이 들어갈 가능성 — Slack 메시지에서 UTF-8 OK.

## 5. 운영 절차

1. **사전 등록** (운영팀): `aws secretsmanager create-secret --name callcenter-{env}-slack-webhook --secret-string "https://hooks.slack.com/services/..."`
2. **Atlantis apply** (PR 머지 후)
3. **smoke test**: `aws stepfunctions start-execution --input '{"bad":"payload"}'` → 3 분 후 Slack 알람 도착 확인

## 6. 테스트 매트릭스 (TDD RED 첫 단계 사전 설계)

### 6.1 단위 (`tests/unit/`)

| Test | 검증 대상 | ADR 가드 |
|---|---|---|
| `test_pii_guard_handler.py::test_handler_emits_pii_metric_per_type` | pii_guard 가 zero-count 스킵 + per-type emit | G2, ADR-003 |
| `test_pii_guard_handler.py::test_pii_metric_does_not_leak_text` | EMF value/dim 어디에도 raw text 없음 | ADR-003 |
| `test_classify_handler.py::test_classify_emits_invoked_and_confidence` | classify 가 두 메트릭 emit | (PR9 신규) |
| `test_classify_handler.py::test_classify_metric_uses_xlsx_code_verbatim` | NONEY/PAYNENT 같은 원본 코드 그대로 dim 값 | ADR-004 |

### 6.2 통합 (`tests/integration/test_observability_definition.py`)

| Test | 검증 대상 | ADR 가드 |
|---|---|---|
| `test_sns_alerts_topic_defined` | SNS topic 리소스 존재 | — |
| `test_slack_relay_lambda_inline_archive` | inline `archive_file` 패턴 | ADR-005 |
| `test_slack_relay_uses_urllib_only` | requests 등 third-party import 0 | ADR-005 |
| `test_slack_relay_iam_no_kms_grant` | IAM policy 에 kms:* 0 | ADR-006 |
| `test_slack_relay_iam_log_group_scoped` | logs 권한이 자기 log group ARN 만 | ADR-006 (tight IAM 원칙) |
| `test_slack_webhook_variable_sensitive` | sensitive=true | G1 |
| `test_observability_does_not_create_secret` | aws_secretsmanager_secret 리소스 0 | ADR-009 |
| `test_five_required_alarms_defined` | 5 알람 모두 정의 | — |
| `test_all_alarms_route_to_sns` | 5 알람 모두 alerts topic 으로 fan-out | — |
| `test_sfn_failure_alarm_uses_state_machine_arn_dim` | SFN ARN dim 사용 | ADR-007 |
| `test_hitl_alarm_is_sustained_not_spike` | evaluation_periods=12 + datapoints=12 | spec §2.2 |
| `test_dashboard_uses_callcenter_namespace` | 모든 custom 메트릭이 namespace 일관 | — |
| `test_dashboard_includes_pii_per_type_widget` | phone/rrn/account/card 4 종 dim | spec §2.3 |
| `test_outputs_expose_alerts_topic_and_alarms` | outputs.tf 가 smoke 검증 가능 | spec §5 |

### 6.3 회귀 가드 (기존 테스트 유지)

- 모든 기존 42 테스트가 변경 없이 통과해야 함 (PR9 가 다른 모듈 회귀 일으키면 fail)

## 7. 산출물 인벤토리

- 신규: `infra/modules/observability/{main.tf, variables.tf, outputs.tf}` (3 파일)
- 수정: `src/lambdas/pii_guard/handler.py`, `src/lambdas/classify/handler.py` (emit 추가)
- 수정: `infra/envs/dev/{main.tf, outputs.tf}` (module wiring + outputs)
- 신규: `tests/integration/test_observability_definition.py`
- 수정: `tests/unit/test_pii_guard_handler.py`, `tests/unit/test_classify_handler.py` (각 +1 test)

## 8. 미해결 / 후속 의제

- PR8 의 `classification.hitlPending` emit 위치 — Streamlit 결정 시 알람 활성 (PR9 는 알람 정의까지만)
- Phase 2 PagerDuty 채널 — SNS subscription 추가 형태로 확장 가능
- `bedrock_throttle` 알람이 `AWS/Lambda/Errors` 를 보지만 Bedrock 의 직접적 throttle 시그널은 Lambda 외부 — Phase 2 에서 `AWS/Bedrock/Invocations` 별도 추적
