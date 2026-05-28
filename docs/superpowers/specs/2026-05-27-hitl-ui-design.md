# HITL UI 시스템 명세서 (PR8)

- **작성일**: 2026-05-27
- **저자**: project owner
- **범위**: Phase 1 PR8 — 운영팀 검수 / 분석팀 검색 / 컴플라이언스 감사용 Streamlit UI
- **선행 의존**: PR1~PR6 머지, PR9 (Observability) 머지 — `classification.hitlPending` 알람 활성을 위해 HITL UI 가 메트릭 emit 필요
- **자율 실행 범위**: Streamlit 코드 + Dockerfile + Terraform 정의 + test. **제외**: `terraform apply`, `docker push`, Cognito user 생성, ACM 인증서 발급

## 1. 목표

검수 / 검색 / 감사 흐름을 하나의 사내 인트라넷 UI 로 제공한다:

1. **운영팀 (ops 그룹)**: HITL 검수 대기열 — `status=hitl-pending` 항목을 사람이 직접 보고 분류 확정 / 교정 / 스킵
2. **분석팀 (analyst 그룹)**: 상담원 ID 또는 대분류 코드로 분류 결과 검색
3. **컴플라이언스 (compliance 그룹)**: 원본 STT raw 다운로드 (감사 로그 = CloudTrail S3 GetObject 이벤트)

**비목표**:
- 일반 사용자 (고객 / 외부) 접근 — 항상 사내 인트라넷 + Cognito 인증
- 검색의 풀텍스트 색인 (transcript) — Athena 쿼리 / QuickSight 에 위임
- 분류 트리 편집 — xlsx 가 single source of truth (PR1)
- Real-time push — Streamlit polling (rerun on button)

## 2. 시스템 컴포넌트

```
사용자 (사내 인트라넷)
    │ HTTPS
    ▼
ALB (internal, TLS 1.3)
  └── authenticate-cognito → Cognito user pool (3 그룹: ops / analyst / compliance)
  └── forward → Target Group → ECS Fargate task (Streamlit)
                                  ├── DDB (consult-results, 3 GSI)
                                  ├── S3 stt-masked (transcript 표시)
                                  └── S3 stt-raw (presigned URL — compliance only)
```

### 2.1 페이지 명세

| 페이지 | 경로 | 그룹 | 주요 흐름 |
|---|---|---|---|
| 진입 | `/` | ops, analyst, compliance | 인사말 + 좌측 사이드바 안내 |
| 검토 큐 | `/pages/1_review_queue` | ops | `list_review_queue()` 페이지네이션 → 단건 선택 → confirm/correct/skip 액션 |
| 검색 | `/pages/2_search` | ops, analyst | agentId 또는 대분류 code 입력 → table 표시 |
| 컴플라이언스 | `/pages/3_compliance` | compliance | callId 입력 → raw S3 presigned URL (5 분 유효) 발급 |

### 2.2 DDB 접근 패턴

| 함수 | 사용 인덱스 | KeyCondition | ExpressionAttributeNames |
|---|---|---|---|
| `list_review_queue(last_key)` | `status-classifiedAt-index` | `#s = :pending` | `#s → status` |
| `search_by_agent(agent_id)` | `agentId-classifiedAt-index` | `agentId = :a` | (none) |
| `search_by_category(da_code)` | `category-daecode-classifiedAt-index` | `#daecode = :c` | `#daecode → category_대code` |
| `get_call(call_id)` | (base table) | `callId = :id` | (none) |
| `update_correction(...)` | (base table UpdateItem) | — | `#s → status` |
| `update_skip(...)` | (base table UpdateItem) | — | `#s → status` |

### 2.3 인증 / 인가

- **인증**: ALB authenticate-cognito 액션이 X-Amzn-Oidc-* 헤더 주입
- **인가**: Streamlit `lib.auth.require_group(allowed)` 가 `cognito:groups` 클레임 검사
- **LOCAL_DEV escape**: `LOCAL_DEV=1` 환경변수 — pytest / 개발 환경에서 ALB 헤더 없이 모든 그룹 허용

## 3. ADR Decision 보존 매트릭스

| ADR | Decision | 본 PR8 의 영향 | 보존 방식 | 검증 test |
|---|---|---|---|---|
| ADR-001 | InferenceAdapter | 없음 (UI 는 LLM 호출 X) | classify Lambda 코드 변경 0 | 기존 회귀 |
| ADR-002 | 2-breakpoint cache | 없음 | — | — |
| ADR-003 | 3-layer PII guard | UI 가 reason 표시 (이미 sanitized) | `update_correction` 이 reason 필드 변경 X — 새 PII 진입 경로 없음 | `test_update_correction_does_not_touch_reason` |
| ADR-004 | xlsx 코드 보존 | 화면에 code + 한국어 라벨 함께 | format string 에서 `{name} ({code})` — code 변환 0 | `test_taxonomy_selector_preserves_code_verbatim` |
| ADR-005 | per-Lambda staging | HITL UI 는 Lambda 가 아닌 ECS — 별도 packaging | `infra/modules/hitl-ui/` 가 ECR + Docker, classify-pipeline 영향 0 | `test_hitl_module_uses_ecr_not_lambda` |
| ADR-006 | KMS 데이터 클래스 분리 | ECS task role 의 KMS scope 결정 필요 | grant: ddb / masked / raw (compliance 페이지 SignedURL 용) — **analytics CMK grant X** | `test_ecs_task_kms_grants_minimal` |
| ADR-007 | SFN Express | HITL 결정이 SFN 외부 | `update_correction` 이 DDB 직접 update — SFN start_execution 호출 0 | `test_update_correction_does_not_trigger_sfn` |
| ADR-008 | 한국어 attribute + ASCII GSI | DDB query 에서 placeholder 패턴 필수 | `IndexName="category-daecode-classifiedAt-index"` + `ExpressionAttributeNames={"#daecode": "category_대code"}` | `test_search_by_category_uses_ascii_index_name` |
| ADR-009 | Atlantis | Cognito user 사전 생성 안 함 | 모듈은 user pool 만, user 자체 X | `test_hitl_module_does_not_create_cognito_user` |
| ADR-010 | global Bedrock CRIS | 없음 | — | — |

### 3.1 추가 보안 가드

- **G5**: ECS task role 의 `dynamodb:*` 권한은 `consult-results` table + `index/*` 만 (다른 테이블 0)
- **G6**: `dynamodb:*` action 도 specific (Query, GetItem, UpdateItem) — Scan / DeleteItem 거부
- **G7**: ALB 는 internal — 인터넷 노출 0 (security group ingress 10.0.0.0/8)
- **G8**: ECR repository `image_tag_mutability=IMMUTABLE` — 태그 hijack 방지
- **G9**: Cognito password policy 12+ chars, 4 종 (lowercase/uppercase/numbers/symbols)
- **G10**: ALB listener `ssl_policy=ELBSecurityPolicy-TLS13-1-2-2021-06` — TLS 1.3
- **G11**: ECS task role 의 `logs:*` 권한은 자기 log group ARN 만 — Resource = `*` 거부

## 4. 운영 절차

1. **사전 요구사항** (운영팀):
   - 사내 도메인 `hitl.callcenter-{env}.kakaopay.internal` 에 대한 ACM 인증서 발급
   - PR 머지 후 Atlantis apply (ECR + ALB + Cognito + ECS 생성)
   - Docker image build → ECR push (수동 또는 PR10 의 CI/CD 자동화)
   - ECS service `update-service --force-new-deployment`
   - Cognito user 생성 (운영 / 분석 / 컴플라이언스 인원별)

2. **smoke**: 사내망에서 ALB DNS 접속 → Cognito 로그인 → 검토 큐 페이지 표시

## 5. 산출물 인벤토리

- **Streamlit 앱**:
  - `src/hitl_ui/streamlit_app.py` (entry)
  - `src/hitl_ui/pages/{1_review_queue,2_search,3_compliance}.py`
  - `src/hitl_ui/lib/{auth,ddb_access}.py`
  - `src/hitl_ui/requirements.txt`
  - `src/hitl_ui/Dockerfile`
- **Terraform**:
  - `infra/modules/hitl-ui/{main,variables,outputs}.tf`
  - `infra/envs/dev/main.tf` (module wiring)
  - `infra/envs/dev/outputs.tf` (ALB DNS, ECR URL 등 outputs)
- **테스트**:
  - `tests/unit/test_hitl_ddb_access.py`
  - `tests/unit/test_hitl_auth.py`
  - `tests/integration/test_hitl_ui_definition.py`

## 6. 테스트 매트릭스

### 6.1 단위 `tests/unit/test_hitl_ddb_access.py`

| Test | 검증 대상 | ADR 가드 |
|---|---|---|
| `test_list_review_queue_uses_status_index` | `IndexName=status-classifiedAt-index` + KeyCondition + ExpressionAttributeNames | spec §2.2 |
| `test_search_by_category_uses_ascii_index_name` | `IndexName=category-daecode-classifiedAt-index` (ASCII) + 한국어 attribute placeholder | ADR-008 |
| `test_search_by_category_preserves_xlsx_code` | NONEY 코드를 그대로 KeyCondition value 로 사용 | ADR-004 |
| `test_search_by_agent_uses_agent_index` | `IndexName=agentId-classifiedAt-index` | spec §2.2 |
| `test_get_call_uses_base_table` | base table `GetItem` (인덱스 사용 X) | — |
| `test_update_correction_writes_status_and_codes` | UpdateItem 이 status / 대code / 중code / 소code 만 변경 | — |
| `test_update_correction_does_not_touch_reason` | `reason` 컬럼이 update expression 에 없음 (ADR-003 PII 가드) | ADR-003 |
| `test_update_correction_does_not_trigger_sfn` | stepfunctions client 인스턴스 0 — DDB UpdateItem 만 | ADR-007 |
| `test_update_skip_writes_skipped_status` | status=hitl-skipped 만 update | spec §2.1 |

### 6.2 단위 `tests/unit/test_hitl_auth.py`

| Test | 검증 대상 |
|---|---|
| `test_decode_oidc_jwt_payload` | JWT middle segment base64 디코딩 |
| `test_current_user_returns_email_from_oidc` | OIDC payload 의 `email` claim 추출 |
| `test_current_groups_returns_cognito_groups` | `cognito:groups` claim → list |
| `test_local_dev_escape_grants_all_groups` | `LOCAL_DEV=1` 시 dev-user + 3 그룹 |
| `test_local_dev_escape_disabled_when_env_unset` | `LOCAL_DEV` 미설정 시 OIDC 헤더 의존 |

### 6.3 통합 `tests/integration/test_hitl_ui_definition.py`

| Test | 검증 대상 | ADR 가드 |
|---|---|---|
| `test_hitl_module_files_exist` | main/variables/outputs.tf 3 파일 | — |
| `test_ecr_repo_is_immutable` | `image_tag_mutability = "IMMUTABLE"` | G8 |
| `test_cognito_password_policy_12_chars_4_classes` | 12+ chars + 4 종 강제 | G9 |
| `test_cognito_user_groups_define_three_roles` | ops / analyst / compliance 3 그룹 모두 정의 | spec §2.3 |
| `test_alb_is_internal_not_public` | `internal = true` + ingress 10.0.0.0/8 | G7 |
| `test_alb_listener_uses_tls13` | `ssl_policy = "ElbSecurityPolicy-TLS13-..."` | G10 |
| `test_ecs_task_kms_grants_minimal` | ECS task IAM 에 ddb / masked / raw KMS 만, analytics 0 | ADR-006 |
| `test_ecs_task_iam_dynamodb_scoped_to_table_and_index` | dynamodb Resource 가 var.ddb_consult_arn + `/index/*` 만 | G5 |
| `test_ecs_task_iam_dynamodb_actions_minimal` | Query/GetItem/UpdateItem 만, Scan/DeleteItem 거부 | G6 |
| `test_ecs_task_iam_logs_scoped_to_log_group` | logs Resource 가 자기 log group ARN 만 | G11 |
| `test_hitl_module_does_not_create_cognito_user` | `aws_cognito_user` 리소스 0 | ADR-009 |
| `test_hitl_module_uses_ecr_not_lambda` | `aws_ecr_repository` 있음, `aws_lambda_function` 0 | ADR-005 |
| `test_dockerfile_uses_python_312_slim_base` | base image = python:3.12-slim | — |
| `test_dockerfile_streamlit_headless_mode` | `--server.headless=true` | spec §2 |

### 6.4 회귀

- 기존 60 test (PR9 머지 후) 모두 통과 유지

## 7. 미해결 / 후속 의제

- HITL UI 가 emit 할 `classification.hitlPending` 메트릭의 빈도 — Streamlit polling 또는 startup probe 결정 필요 (PR9 알람 트리거 조건). 일단 본 PR 에서는 페이지 진입 시 1 회 emit (운영팀 검토 시 가시화 자동).
- ACM 인증서 발급 절차 — 사내 PKI 의존, 별도 트랙.
- Phase 2 에서 검토 큐 multi-user 동시 작업 시 lock — DDB ConditionExpression `status = "hitl-pending"` 추가 (현재는 마지막 write wins, 동시 작업 흔치 않다 가정).
