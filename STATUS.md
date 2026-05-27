# 자율 실행 결과 — Phase 1 PR1~PR6

**기간**: 2026-05-22 → 2026-05-26 (사용자 수면 중 자율 진행)
**범위**: subagent-driven-development 스킬로 Phase 1 plan의 PR1~PR6 실행
**현재 HEAD**: `c8c867a` (origin/main, GitHub: `Atom-oh/call-center-admin`)
**테스트 현황**: 42 passed, 0 failed
**Terraform 현황**: dev env `fmt -check` clean, `validate` Success (apply는 안 함)

## 자율 실행 원칙 (지키지 않은 것 / 지킨 것)

| 행동 | 진행 여부 |
|------|----------|
| Python/Terraform 코드 작성 | ✅ |
| 단위/통합 테스트 작성 + pytest 실행 | ✅ |
| `terraform fmt -recursive` / `validate` (offline) | ✅ |
| git commit + push to `Atom-oh/call-center-admin` | ✅ |
| `terraform apply` (실제 AWS 리소스 생성) | ❌ 의도적 미수행 |
| `aws lambda/s3/ecs/cognito ...` mutating CLI | ❌ 의도적 미수행 |
| `docker push` to ECR | ❌ 의도적 미수행 |
| Bedrock 실제 호출 (`eval_prompt.py` 등) | ❌ 의도적 미수행 |
| Slack webhook 등록, Cognito user 생성 | ❌ 외부 자격 필요 |

## 완료된 PR

각 PR은 (a) implementer subagent dispatch → (b) spec compliance reviewer → (c) code quality reviewer → (d) reviewer 발견 사항 fix-commit 사이클을 거쳤습니다.

### PR1 — 프로젝트 초석 + 분류체계 파서 ✅
- **커밋**: `43796a0`, `c140e50`, `5cb2079`, `32374cd`(fix)
- **테스트**: 5 → 8 (fix로 3 추가: round-trip JSON, marker counts, "code: None" omission)
- **산출물**:
  - `pyproject.toml` (Python 3.12, openpyxl/boto3/pydantic, dev 도구)
  - `ruff.toml`, `README.md` (재생성 명령 문서화)
  - `src/lib/taxonomy.py` — xlsx → 213 노드 트리 (`TaxonomyNode` 데이터클래스 + `parse_xlsx` + DFS serializer + JSON encoder)
  - `scripts/parse_taxonomy.py` CLI
  - `src/prompts/v1.0/taxonomy_tree.{json,md}` 산출물 커밋 (18/64/131 노드)
- **review fix가 잡은 것**: 64개 중분류 노드가 description 비어 있었는데 serializer가 raw `description` 만 보고 있어서 LLM 프롬프트에 설명이 안 들어가는 버그 + 코드 `None` 노드가 `"code: None"` 문자열로 렌더링되는 버그 → effective_description 사용 + None code 접미사 생략

### PR2 — Terraform shared + storage 모듈 ✅
- **커밋**: `097ab47`, `2a22939`, `caaeeeb`, `348800c`(fix)
- **테스트**: terraform validate (모듈/dev 양쪽 통과)
- **산출물**:
  - `infra/shared-state/main.tf` — S3 tfstate 버킷 + DynamoDB lock 테이블
  - `infra/modules/shared/` — VPC, 3 private subnets, S3 Gateway + 8 Interface VPC endpoints (bedrock-runtime, dynamodb, kms, states, secretsmanager, ecr.{dkr,api}, logs)
  - `infra/modules/storage/` — KMS CMKs ×4 (raw/masked/analytics/ddb, rotation enabled), S3 buckets ×4 (versioning + SSE-KMS + PAB), lifecycle (raw → Glacier IR 90d → Deep Archive 365d; masked → expire 365d + non-current 30d), DynamoDB `consult-results` (3 GSIs: status/agentId/category_대code, streams, TTL, PITR), 2 SQS DLQs
  - `infra/envs/dev/` — backend, provider, modules wired
- **review fix가 잡은 것**: lifecycle 룰에 `filter {}` 누락 (AWS provider 6.x에서 reject 예정), non-current version expiration 누락 (versioned 버킷에서 데이터 영구 잔존), GSI3 이름이 attribute 이름과 underscore 차이로 불일치 (DDB index rename은 table replacement 요구 → apply 전 수정), analytics/ml ARN + DDB stream ARN dev 출력 누락

### PR3 — PII Guard Lambda + 정규식 ✅
- **커밋**: `ca330c6`, `e8cb1be`, `df4ed14`, `6f7b5e9`(fix)
- **테스트**: 8 → 9 (fix로 1 추가: over-greedy 회귀)
- **산출물**:
  - `src/lib/pii_regex.py` — 4 패턴 (휴대폰/주민/계좌/카드), Luhn 검증, `MaskStats` 데이터클래스
  - `src/lambdas/pii_guard/handler.py` — S3 raw 읽고 마스킹된 텍스트를 S3 masked에 KMS 암호화 저장
  - `infra/modules/classify-pipeline/` 모듈 첫 진입 (PII Guard Lambda + IAM + log group)
- **review fix가 잡은 것**: 카드 정규식 `(?:\d[ -]?){13,19}` 가 over-greedy해서 `0 4532-...` 같이 짧은 digit이 앞에 있으면 17 iteration 매치 → Luhn 실패 → 카드 마스킹 누락; IAM `logs:CreateLogGroup Resource="*"` 불필요 → 제거 + 특정 log group ARN으로 좁힘
- **Korean text 특이사항**: 원본 plan의 `\b` 워드 경계는 한글 jamo가 `\w`로 잡혀서 동작 안 함 → `(?<!\d)/(?!\d)` digit-boundary로 대체 (functionally 더 정확)

### PR4 — Classify Lambda + 프롬프트 v1.0 + 골든셋 ✅
- **커밋**: `3c9b558`, `8d2bb4c`, `896aa91`, `65683f0`, `579acc2`(fix)
- **테스트**: 9 → 24 (test_output_schema 4, test_prompts 2, test_classify_handler 1; fix로 4 추가: top-level dict, bool confidence, level bounds, expected codes count)
- **산출물**:
  - `src/prompts/v1.0/system_rules.md` — 역할 / 절대원칙 / R1~R5 (R5 PII 인용 금지)
  - `src/lib/output_schema.py` — `parse_and_validate` (markdown fence 처리, JSON 유효성, 코드 검증, confidence 범위 검증)
  - `src/lib/prompts.py` — `PromptBundle` + 2개 cache breakpoint 구조
  - `src/lib/bedrock_client.py` — Bedrock Converse + `{"cachePoint": {"type": "default"}}`
  - `src/lib/inference_adapter.py` — Protocol (Phase 3 ML adapter 호환)
  - `src/lambdas/classify/handler.py` — Bedrock Opus 4.7 (서울 리전) 호출
  - `tests/golden/samples.json` — 5-row scaffold (g001 real, g002-g005 TBD)
  - `scripts/eval_prompt.py` — 골든셋 평가 CLI (`--skip-tbd` 플래그)
  - **Terraform per-Lambda staging-dir 패키징 패턴** 도입 — `data "external"` bash 스크립트가 Lambda별 `build/{name}/` 디렉토리에 필요한 모듈만 복사 → archive_file zip. PR3의 exclude-list 패턴 폐기. PR5/PR6에서 그대로 재사용.
- **review fix가 잡은 것**: `output_schema.parse_and_validate`가 top-level이 dict 아닐 때 AttributeError 발생 → ValidationError로 surface; Python의 `True`가 `isinstance(int, float)` 통과해서 confidence=True 가 silently 1.0으로 받아들여지는 버그 → 명시적 bool 거부; taxonomy 노드 level이 1-3 아닐 때 silent wrap (음수 인덱스) → ValueError; inert `local_file.pii_guard_stage_marker` 제거

### PR5 — Verify Lambda + 캐스케이드 분기 ✅
- **커밋**: `ca42dec`, `b0fe8dd`, `f4a455d`, `23b31d5`(fix)
- **테스트**: 24 → 33 (test_metrics 2, test_verify_handler 3)
- **산출물**:
  - `src/lib/metrics.py` — CloudWatch Embedded Metric Format (EMF) helper, `emit(name, value, **dims)` → stdout JSON. try/except로 격리 (fix에서)
  - `src/lambdas/verify/handler.py` — Sonnet 4.6 호출 → primary(Opus)와 대/중/소 코드 비교 → 합의 시 `verified=auto-confirmed`/`status=confirmed`, 불일치 시 `status=hitl-pending`
  - Terraform: verify staging-dir + Lambda + IAM (Bedrock `claude-sonnet-4-*` 전용)
- **review fix가 잡은 것**: `modelPath[0] = event.get("modelId")` 가 `None` 일 수 있어서 다운스트림 분석 query에서 문제 → hard-fail (`event["modelId"]` 직접 인덱싱); primary 모양 검증 `_assert_primary_shape` 추가 (Bedrock 비용 청구 전에 스키마 drift를 잡음); `emit` 안에 try/except — 직렬화 실패가 Lambda 자체를 죽이지 않도록 (observability는 working path를 절대 깨트리지 말 것); `agreement="agree"/"disagree"` 으로 CloudWatch Insights 가독성 개선
- **테스트 isolation**: module-level `_ADAPTER` 캐시 때문에 fixture에 `sys.modules.pop` 필요. spec에 명시된 module-level instantiation 패턴 유지를 위한 테스트-쪽 워크어라운드.

### PR6 — Persist Lambda + Step Functions Express + EventBridge ✅
- **커밋**: `dd9e2c9`, `91f0bbe`, `f6e7a87`, `c8c867a`(fix)
- **테스트**: 33 → 42 (test_persistence 4, test_persist_handler 3, test_sfn_definition 1; fix로 1 추가: promptVersion conflict)
- **산출물**:
  - `src/lib/persistence.py` — 출력 후처리 PII sweep + `build_ddb_item` (모든 필드 + TTL +1y + reason/why_rejected 2KB/500B cap)
  - `src/lambdas/persist/handler.py` — DDB put_item with ConditionExpression (`attribute_not_exists OR promptVersion=:pv`) + 옵션 Firehose put + EMF 메트릭 emit. ConditionalCheckFailedException 처리 추가 (fix에서)
  - **Step Functions Express state machine** — 8 states: PiiGuard → Classify → ConfidenceBranch → (Verify | MarkAutoHigh) → Persist + 2 DLQ states (SendToClassifyDlq, SendToPersistDlq). Retry 정책: classify 5회 (Throttling/ServiceUnavailable), 그 외 3회. Catch → DLQ.
  - **EventBridge S3 트리거** — `aws_s3_bucket_notification` (eventbridge=true) + rule (s3 Object Created, .json suffix) + IAM role + target with `input_transformer` (`{"rawBucket": ..., "rawKey": ...}`)
- **review fix가 잡은 것**: persist Lambda IAM에서 `kms:* Resource="*"` 였음 → `kms_ddb_arn` 변수 추가하고 DDB CMK ARN으로 좁힘 (firehose는 PR7에서 narrow 예정으로 코멘트); `ConditionalCheckFailedException`이 promptVersion drift 시 SFN retry 3회 후 DLQ로 → DLQ가 transient error와 구분 안 됨 → silent skip + `classification.skippedExisting` 메트릭 emit으로 변경; `modelPath` None 필터 (defensive)

## 최종 디렉토리 구조

```
call-center-admin/
├── .github/                  (PR10 — 미진행)
├── .gitignore                (.terraform, .venv, infra/modules/*/build/, .env 등)
├── docs/
│   ├── runbooks/             (PR10 — 미진행)
│   └── superpowers/
│       ├── plans/            ← Phase 1 (10 PR) + Phase 3 (9 ML-PR) plan 파일 2개
│       └── specs/            ← 설계서 1개
├── infra/
│   ├── envs/dev/             ← backend, variables, main, outputs (stg/prd는 PR10)
│   ├── modules/
│   │   ├── shared/           ← VPC, subnets, 8 VPC endpoints
│   │   ├── storage/          ← KMS×4, S3×4, DDB+3GSIs, DLQ×2
│   │   └── classify-pipeline/ ← Lambda×4 + SFN + EventBridge (analytics/hitl-ui/observability는 PR7-9)
│   └── shared-state/         ← tfstate S3 + DDB lock
├── scripts/
│   ├── eval_prompt.py        ← 골든셋 평가 CLI (Bedrock 호출 — apply 후 실행)
│   └── parse_taxonomy.py     ← xlsx → JSON 변환기
├── src/
│   ├── lambdas/{pii_guard,classify,verify,persist}/  ← 4 Lambda handlers
│   ├── lib/                  ← taxonomy, pii_regex, prompts, output_schema, bedrock_client,
│   │                            inference_adapter, persistence, metrics
│   └── prompts/v1.0/         ← system_rules.md + taxonomy_tree.{json,md}
├── tests/
│   ├── golden/               ← samples.json scaffold (5 rows, 1 real)
│   ├── integration/          ← test_sfn_definition.py (static structure check)
│   └── unit/                 ← 42 tests across 8 files
├── pyproject.toml            (Python 3.12, dev extras: pytest/moto/ruff/mypy)
├── README.md
├── STATUS.md                 ← 본 파일
└── 상담어시스트_AWS전달자료.xlsx  ← 분류체계 원본 (NFD 파일명)
```

## 미진행 (사용자 승인 또는 외부 자격 필요)

| PR | 이유 |
|----|------|
| **PR2 `terraform apply`** | 실제 AWS 리소스 생성 — 비용 + 컴플라이언스 |
| **PR3-6 dev 배포 후 smoke test** | `terraform apply` 의존 |
| **PR4 `eval_prompt.py`로 골든셋 평가** | Bedrock 실호출 비용 + 골든셋이 1행만 실제 라벨 (50-100건 손라벨링 deferred) |
| **PR7 Analytics** (Glue/Firehose/Athena/QuickSight) | apply 의존 + QuickSight 콘솔 작업 일부 필요 |
| **PR8 HITL UI** (Streamlit on Fargate + Cognito + ALB) | apply + Docker push + Cognito user 생성 + ACM 인증서 |
| **PR9 Observability** | apply + Slack Webhook URL (Secrets Manager 등록) |
| **PR10 CI/CD + stg/prd + 런북** | OIDC IAM role 생성, GitHub Actions secret, stg/prd 환경 변수 |

## 다음 단계 (사용자가 일어난 후)

### 즉시 (코드 리뷰 + apply 전 점검)

1. **`docs/superpowers/specs/2026-05-22-callcenter-stt-classification-design.md` §10 미해결 항목 확인**:
   - 사내 컴플라이언스: "Raw STT 외부 송신 (Bedrock 호출)" 허용 여부 — **Phase 1 진입 전 차단 요소**
   - Bedrock 서울 리전 쿼터 사전 신청 (Opus 4.7 RPM 60 / Sonnet 4.6 RPM 30)
   - 골든셋 50-100건 손 라벨링 담당자 지정

2. **본 자율 실행 결과 코드 리뷰**: 27개 신규 커밋 (`5cb2079..c8c867a`). 특히 다음 결정점 확인:
   - 한글 attribute (`category_대code`) DDB 컬럼 — 다운스트림 BI 도구 호환성
   - Bedrock model ID — `apac.anthropic.claude-opus-4-7-20260101-v1:0`, `apac.anthropic.claude-sonnet-4-6-20260101-v1:0` (APAC cross-region inference profile; ap-northeast-2 에서 foundation-model 직접 호출은 불가하므로 `apac.` prefix 필수)
   - SFN 멤핑 게이트: confidence < 0.80에 verify, ≥ 0.80에 MarkAutoHigh — 임계값 조정 의향

3. **dev `terraform apply`**:
   ```bash
   cd infra/shared-state && terraform init && terraform apply
   cd ../envs/dev && terraform init && terraform apply
   ```
   비용 추정: 일 ~$25 (DDB on-demand + Bedrock cache hit 가정 + DLQ + log groups). 본 시점에는 SFN 트리거가 작동하지만 raw 버킷에 STT JSON 업로드가 없으니 실제 비용은 거의 0.

4. **첫 smoke test** (apply 후):
   ```bash
   cat > /tmp/smoke.json <<EOF
   {"callId":"smoke_001","agentId":"A1","startedAt":"2026-05-26T00:00:00Z","durationSec":60,
    "transcript":[{"speaker":"customer","text":"페이머니 충전이 안되는데요"}]}
   EOF
   aws s3 cp /tmp/smoke.json s3://kakaopay-callcenter-dev-stt-raw/2026/05/26/smoke_001.json
   sleep 30
   aws stepfunctions list-executions --state-machine-arn $(terraform -chdir=infra/envs/dev output -raw sfn_arn) --max-items 1
   aws dynamodb get-item --table-name callcenter-dev-consult-results --key '{"callId":{"S":"smoke_001"}}'
   ```

### 중기 (Phase 1 잔여 PR)

`docs/superpowers/plans/2026-05-22-phase1-callcenter-classification.md` 의 PR7-PR10이 plan으로 남아 있음. plan의 step-by-step 가이드대로 같은 subagent-driven 패턴으로 진행 가능. 다만 PR7+ 부터는 Docker / Cognito user / Slack webhook 등 외부 자격이 필요하므로 사용자 input이 필요.

### 장기 (Phase 3 MLOps)

`docs/superpowers/plans/2026-05-22-phase3-mlops-continuous-learning.md`. HITL real label ~500건 누적 후 진입. classify Lambda의 `InferenceAdapter` 추상화 덕분에 ML 캐스케이드는 코드 변경 최소화로 끼워 넣을 수 있음 (Phase 1 코드는 이미 호환 인터페이스 구현됨).

## 자율 실행에서 채택한 결정 (사용자가 뒤집고 싶을 수 있는 것)

1. **자동 학습 promptVersion conflict → silent skip**: 동일 callId가 다른 promptVersion으로 재처리될 때 새 버전이 거부됩니다. 만약 backfill 시 새 버전으로 **덮어쓰기** 의도라면 다른 로직이 필요. (`src/lambdas/persist/handler.py:36-49` 참조)

2. **KMS scope on persist Lambda**: `kms:* Resource = kms_ddb_arn` 으로 좁혔습니다. 만약 persist Lambda가 미래에 다른 CMK를 다뤄야 하면 (예: Parquet 결과를 KMS로 다시 암호화) scope 확장 필요.

3. **카드 정규식 변경**: spec의 `\b(?:\d[ -]?){13,19}\b` → 실제 `(?<!\d)\d(?:[ -]?\d){12,18}(?<=\d)` (한글 boundary 대응 + over-greedy 방지). 동일 카드 패턴을 잡지만 boundary 조건이 다름. 만약 통제된 입력에서 spec 그대로 가야 한다면 되돌릴 것.

4. **SFN MarkAutoHigh의 `States.Array($.modelId)`**: ASL intrinsic을 unquoted JsonPath로 호출. 만약 SFN 검증이 quoted form을 요구하면 (`"$.modelId"`) AWS 콘솔 import 시 에러 가능 — 첫 apply 시 확인 필요.

5. **`category_대code` 한글 attribute**: 그대로 유지. 만약 BI 도구나 Athena Insights 사용 시 인용 부담이 크면 ASCII fallback 컬럼 (`category_top_code` 등) 추가 검토.

## 통계

- **신규 커밋**: 27개 (자율 실행 기간 동안 `5dfc322` 이후)
- **신규 파일**: ~50개 (Python ~25, Terraform ~10, tests ~10, docs ~5)
- **신규 코드 라인**: ~3,500 line (cumulative diff)
- **신규 단위 테스트**: 42개 (전부 통과)
- **dispatch한 subagent**: 12개 (6 implementer + 6 reviewer) + 다수 follow-up edit
- **subagent timeout 1회** (PR1 fix agent) — 다행히 디스크에 부분 수정이 남아 있어 직접 마무리

## 남긴 TODO

- `src/lambdas/*/handler.py` 의 `sys.path.insert` 핵 (4 곳) — TODO(phase2) 코멘트로 marked. Lambda Layer로 분리 시 일괄 정리 가능
- 통합 테스트는 텍스트 grep 기반 — stepfunctions-local 기반의 진짜 dry-run으로 업그레이드 가능
- 골든셋 g002-g005 손 라벨링 (분석팀 또는 외주)
- PR9에서 좁혀야 할 IAM allow-all: persist Lambda의 `firehose:* Resource="*"`, SFN role의 `logs:* Resource="*"` (logs:*LogDelivery 는 `*` 필수지만 CreateLogStream/PutLogEvents는 좁힐 수 있음)

---

**Git remote**: https://github.com/Atom-oh/call-center-admin
**Final HEAD**: `c8c867a` on `main`
**Last test run**: 42 passed
**Last terraform check**: dev validate Success, fmt clean
