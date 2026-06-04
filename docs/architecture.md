# Architecture

[![English](https://img.shields.io/badge/Language-English-blue)](#english) [![한국어](https://img.shields.io/badge/언어-한국어-red)](#한국어)

---

## English

### System Overview

`call-center-admin` is an asynchronous, event-driven classification pipeline that consumes STT (speech-to-text) transcripts from Amazon S3 and assigns a three-level taxonomy label (대/중/소) using Amazon Bedrock (Claude Opus 4.7 primary + Sonnet 4.6 verify). The system favors accuracy over latency and routes low-confidence/disagreement cases to a human-in-the-loop (HITL) queue, while emitting all results to both DynamoDB (operational) and S3 Parquet (analytics).

### Components by Layer

#### Ingestion
- **S3 `kakaopay-callcenter-<env>-stt-raw`** — caller-side STT producer drops `*.json` transcripts here. KMS-CMK encrypted, versioning ON, lifecycle Glacier IR @ 90d / Deep Archive @ 365d.
- **EventBridge rule `callcenter-<env>-raw-put`** — pattern `s3:Object Created` with `.json` suffix, target = SFN state machine with `input_transformer` projecting `{rawBucket, rawKey}`.

#### Processing (Step Functions Express + Lambdas)
- **PII Guard Lambda** — regex-based hard PII (계좌·카드·주민·휴대폰) masking. Reads raw S3 JSON, writes masked text to `stt-masked/`.
- **Classify Lambda** — Bedrock Opus 4.7 Converse API with two-breakpoint prompt cache (rules + taxonomy tree). Returns `{대/중/소 + confidence + reason + alternativesConsidered}`.
- **Verify Lambda** — Bedrock Sonnet 4.6 cross-verify. Marks `auto-confirmed` on agreement, `hitl-pending` on disagreement. Triggered when classify confidence < 0.80.
- **Persist Lambda** — DDB `put_item` with `attribute_not_exists OR promptVersion=:pv` conditional (idempotent SFN retry), optional Firehose Parquet append, EMF metrics emit, output-side PII sweep.
- **Cache Warmer Lambda** (optional, default-OFF — outside the SFN) — an EventBridge cron invokes `BedrockAdapter.warm()` with the same two-breakpoint system blocks + MODEL_ID as Classify to keep the prompt cache warm (ADR-002). Count-gated on `var.enable_cache_warming`: zero resources / zero cost when `false`.

#### Storage
- **DynamoDB `callcenter-<env>-consult-results`** — PK=`callId`, 3 GSIs (`status` / `agentId` / `category_대code`-by-classifiedAt), DDB Streams (NEW_AND_OLD_IMAGES), TTL=`ttlEpoch`+1y, PITR ON, KMS-CMK SSE.
- **S3 `<prefix>-stt-masked`** — masked transcripts (KMS-CMK), expires after 365d.
- **S3 `<prefix>-analytics`** — Parquet results (PR7), Glue catalog + Athena workgroup (PR7).
- **S3 `<prefix>-ml`** — training sets, model artifacts, eval results (Phase 3).
- **KMS CMKs ×4** — `raw`, `masked`, `analytics`, `ddb` — data-class separation. Rotation enabled.

#### Query / Presentation
- **Athena workgroup `callcenter-<env>`** + Glue table `consult_results` — `infra/modules/analytics/`
- **QuickSight Enterprise** — 5 sheets (overview, drill-down, agent heatmap, quality, alerts); dataset/console setup per `docs/runbooks/quicksight-setup.md`
- **Streamlit on Fargate behind internal ALB + Cognito** — HITL review queue / search / compliance pages. Implemented: `src/hitl_ui/` app + `infra/modules/hitl-ui/`. Fronted by **CloudFront + VPC Origin → Private ALB** (ADR-013); ALB `authenticate-cognito`; review queue uses first-write-wins optimistic lock (ADR-011); 5-year audit log (ADR-012).

#### Observability
- **CloudWatch metrics (EMF)** — `classification.processed`, `classification.confidence`, `classification.verifyTriggered`, `classification.skippedExisting`, `pii.maskApplied`
- **CloudWatch dashboard** — throughput, confidence trend, SFN success rate, DLQ depth
- **5 alarms → SNS → Slack relay Lambda** — SFN-Failure, DLQ-Backlog, Bedrock-Throttling, HITL-Backlog, Cost-Anomaly

#### Security
- **VPC** — 3 private subnets, S3 Gateway endpoint + 8 Interface endpoints (bedrock-runtime, dynamodb, kms, states, secretsmanager, ecr.{dkr,api}, logs). Lambda is VPC-attached (Phase 1 prd; dev acceptable without).
- **IAM least-privilege** — per-Lambda role, Bedrock scoped to model ARN pattern, KMS scoped to data-class CMK, S3 scoped to bucket+prefix.
- **CloudTrail** — all data events ON. raw S3 access auditable.
- **Cognito** — User Pool with 3 groups (`ops`, `analyst`, `compliance`); ALB `authenticate-cognito`. `hitl_lib.auth` verifies the ALB OIDC JWT signature (ES256, key fetched by `kid`) and that the JWT `signer` equals our ALB ARN (`ALB_ARN` env, rejecting tokens minted by other ALBs in the region), fail-closed (ADR-011).
- **CloudFront + VPC Origin + WAF** (ADR-013) — public entry to the HITL UI; viewer ACM cert in us-east-1, ALB HTTPS listener cert in ap-northeast-2.

### Full Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                              │
│ External STT producer ─▶ S3: stt-raw ─▶ EventBridge: Object Created          │
│                          (KMS-raw)        │                                  │
│                                            ▼                                  │
│                                  Step Functions Express                       │
│                                  ┌────────────────────────────────────────┐  │
│                                  │ PiiGuard Lambda                         │  │
│                                  │   regex mask → S3: stt-masked           │  │
│                                  │   (KMS-masked)                          │  │
│                                  └────────┬───────────────────────────────┘  │
│                                           ▼                                   │
│                                  ┌────────────────────────────────────────┐  │
│                                  │ Classify Lambda                         │  │
│                                  │   Bedrock Opus 4.7 (2 cache breakpoints)│  │
│                                  │   ➜ {대/중/소 + confidence + reason}    │  │
│                                  └────────┬───────────────────────────────┘  │
│                                           ▼                                   │
│                                  ┌────────────────────────────────────────┐  │
│                                  │ ConfidenceBranch (Choice state)         │  │
│                                  │   < 0.80 ─▶ Verify                       │  │
│                                  │   ≥ 0.80 ─▶ MarkAutoHigh (Pass state)    │  │
│                                  └────┬───────────────┬───────────────────┘  │
│                                       ▼               ▼                       │
│                              ┌────────────────┐  (skip verify)               │
│                              │ Verify Lambda   │       │                      │
│                              │ Sonnet 4.6      │       │                      │
│                              │ agree/disagree  │       │                      │
│                              └────────┬───────┘       │                      │
│                                       ▼               ▼                       │
│                                  ┌────────────────────────────────────────┐  │
│                                  │ Persist Lambda                          │  │
│                                  │   PII output sweep + DDB put_item       │  │
│                                  │   (+ Firehose Parquet PR7)              │  │
│                                  │   + EMF metrics                          │  │
│                                  └────────┬───────────────────────────────┘  │
│                                           ▼                                   │
│                                  ┌────────────────────────────────────────┐  │
│                                  │ DynamoDB consult-results (3 GSIs, TTL)  │  │
│                                  │ + S3 Parquet (PR7)                      │  │
│                                  └────────────────────────────────────────┘  │
│                                                                              │
│  DLQ paths: Classify failure ─▶ SendToClassifyDlq (SQS)                      │
│             Persist failure ─▶ SendToPersistDlq (SQS)                        │
│                                                                              │
│  Read paths (PR7-8):                                                          │
│     DDB ─▶ Streamlit on Fargate (ops HITL queue, search, compliance)         │
│     S3 Parquet ─▶ Athena ─▶ QuickSight (analyst dashboards)                  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Data Flow Summary

`S3 raw .json → EventBridge → SFN Express(PII → Opus → [confidence ≥ 0.80 → Mark | < 0.80 → Sonnet verify] → Persist) → DynamoDB + S3 Parquet → Athena/QuickSight + Streamlit HITL UI`

### Infrastructure (Terraform Modules)

| Module | Purpose | Source |
|--------|---------|--------|
| `shared` | VPC, 3 private subnets, 8 VPC endpoints, shared SG | `infra/modules/shared/` |
| `storage` | KMS CMK ×4, S3 ×4, DynamoDB + 3 GSIs + TTL + PITR, SQS DLQ ×2 | `infra/modules/storage/` |
| `classify-pipeline` | per-Lambda staging-dir packaging, IAM, log groups, Lambda ×4 + cache_warmer (optional), SFN Express, EventBridge | `infra/modules/classify-pipeline/` |
| `analytics` | Glue, Firehose Parquet, Athena workgroup, QuickSight datasets | `infra/modules/analytics/` |
| `hitl-ui` | Fargate, internal ALB, Cognito, CloudFront + VPC Origin (ADR-013) | `infra/modules/hitl-ui/` |
| `observability` | CW dashboards, 5 alarms, SNS, Slack relay Lambda | `infra/modules/observability/` |
| `continuous-learning` (Phase 3) | SageMaker Pipelines, Model Registry, Endpoint | _pending_ |

### Key Design Decisions

- **Accuracy > latency** — async S3 trigger, no SLA pressure. Allows the strongest model (Opus 4.7) + verify pass + HITL routing.
- **Two prompt-cache breakpoints** — rules block (stable) + taxonomy tree block (changes only when xlsx regenerated). Maximizes cache hit rate.
- **Pluggable inference (`InferenceAdapter` Protocol)** — classify Lambda imports an abstraction so Phase 3 can drop in `MlAdapter` (KLUE-BERT cascade) without changing SFN definition or other Lambdas.
- **xlsx-preserved code identifiers** — `NONEY`/`PAYNENT` typos in the original taxonomy are system identifiers; preserved verbatim everywhere (code, prompts, tests).
- **Three-layer PII guard** — regex (deterministic, hard-PII), prompt R5 (LLM behavior), persist sweep (defense-in-depth against synthetic PII).
- **Per-Lambda staging-dir packaging** — instead of one zip with exclude-list, each Lambda has a `data "external"` script that copies only the modules it needs. Reduces cold-start size and attack surface.
- **DDB ConditionalCheckFailedException → silent skip** — same `callId` re-processed with a different `promptVersion` results in `persisted=False, skipReason="promptVersion-conflict"` rather than DLQ. Keeps DLQ as a true-error signal.
- **HITL optimistic lock (ADR-011)** — `update_correction`/`update_skip` use `ConditionExpression status = hitl-pending`; concurrent reviewers → first-write-wins, the loser gets `AlreadyProcessedError`. Audit is emitted only after a successful write.
- **Opus 4.7 temperature removal (ADR-014)** — Opus 4.7+ rejects `temperature`/`top_p`/`top_k` (ValidationException); `inferenceConfig` carries only `maxTokens`. Determinism is enforced by prompt rules + output-schema validation. Label-stability is measured by `scripts/eval_prompt.py --runs N`.
- **CloudFront + VPC Origin for HITL UI (ADR-013)** — public viewer entry without exposing the ALB; viewer cert in us-east-1, origin cert in ap-northeast-2.

### Operations

- `docs/runbooks/.template.md` — runbook template
- Authored runbooks: `bedrock-throttling.md`, `hitl-backlog.md`, `prompt-rollback.md`, `pii-mask-failure.md`, `quicksight-setup.md`
- Setup guides: `docs/operations/atlantis-setup.md`, `docs/operations/github-actions-setup.md`

---

## 한국어

### 시스템 개요

`call-center-admin` 은 비동기·이벤트 드리븐 분류 파이프라인이다. Amazon S3에 올라오는 STT(녹음→텍스트) 결과를 받아 Amazon Bedrock (Claude Opus 4.7 primary + Sonnet 4.6 verify)로 3단계 분류 라벨(대/중/소)을 부여한다. 지연보다 정확도를 우선시하고, 낮은 신뢰도/모델 간 불일치 케이스는 HITL 큐로 라우팅하며, 모든 결과는 DynamoDB(운영용)와 S3 Parquet(분석용)에 동시에 적재된다.

### 컴포넌트 (레이어별)

#### 인입 (Ingestion)
- **S3 `kakaopay-callcenter-<env>-stt-raw`** — STT 생성 측이 `*.json` 트랜스크립트를 업로드. KMS-CMK 암호화, versioning ON, lifecycle Glacier IR @ 90d / Deep Archive @ 365d.
- **EventBridge rule `callcenter-<env>-raw-put`** — `s3:Object Created` + `.json` suffix, target = SFN state machine. `input_transformer` 가 `{rawBucket, rawKey}` 프로젝션.

#### 처리 (Step Functions Express + Lambda 4종)
- **PII Guard Lambda** — 정규식 기반 하드 PII (계좌·카드·주민·휴대폰) 마스킹. raw S3 JSON 읽고 `stt-masked/` 에 마스킹된 텍스트 write.
- **Classify Lambda** — Bedrock Opus 4.7 Converse API, 2개 cache breakpoint (룰 + 분류 트리). `{대/중/소 + confidence + reason + alternativesConsidered}` 반환.
- **Verify Lambda** — Bedrock Sonnet 4.6 cross-verify. 합의 시 `auto-confirmed`, 불일치 시 `hitl-pending`. confidence < 0.80일 때만 호출.
- **Persist Lambda** — DDB `put_item` (`attribute_not_exists OR promptVersion=:pv` 조건으로 SFN retry idempotent), 선택적 Firehose Parquet, EMF 메트릭, 출력 PII sweep.
- **Cache Warmer Lambda** (옵션, default-OFF — SFN 밖) — EventBridge cron 이 `BedrockAdapter.warm()` 을 Classify 와 동일한 2-breakpoint system 블록 + MODEL_ID 로 호출해 프롬프트 캐시를 워밍 (ADR-002). `var.enable_cache_warming` 으로 count-gate: `false` 면 리소스 0 / 비용 0.

#### 스토리지
- **DynamoDB `callcenter-<env>-consult-results`** — PK=`callId`, 3 GSI (`status` / `agentId` / `category_대code`-by-classifiedAt), DDB Streams (NEW_AND_OLD_IMAGES), TTL=`ttlEpoch`+1년, PITR ON, KMS-CMK SSE.
- **S3 `<prefix>-stt-masked`** — 마스킹 본문 (KMS-CMK), 365일 후 만료.
- **S3 `<prefix>-analytics`** — Parquet 결과 (PR7), Glue catalog + Athena workgroup (PR7).
- **S3 `<prefix>-ml`** — 학습 데이터셋, 모델 산출물, 평가 결과 (Phase 3).
- **KMS CMK ×4** — `raw`, `masked`, `analytics`, `ddb` 데이터 클래스별 분리, rotation 활성.

#### 조회·표시
- **Athena workgroup `callcenter-<env>`** + Glue 테이블 `consult_results` — `infra/modules/analytics/`
- **QuickSight Enterprise** — 5개 시트 (개요, 드릴다운, 상담원 heatmap, 품질, 알람); 데이터셋/콘솔 셋업은 `docs/runbooks/quicksight-setup.md`
- **Streamlit on Fargate behind internal ALB + Cognito** — HITL 검수 큐 / 검색 / 컴플라이언스 페이지. 구현됨: `src/hitl_ui/` 앱 + `infra/modules/hitl-ui/`. **CloudFront + VPC Origin → Private ALB** fronting (ADR-013); ALB `authenticate-cognito`; 검수 큐는 선착순 낙관적 락 (ADR-011); 5년 감사 로그 (ADR-012).

#### 관측성
- **CloudWatch metrics (EMF)** — `classification.processed`, `classification.confidence`, `classification.verifyTriggered`, `classification.skippedExisting`, `pii.maskApplied`
- **CloudWatch 대시보드** — 처리량, confidence 추이, SFN 성공률, DLQ 깊이
- **5개 알람 → SNS → Slack relay Lambda** — SFN-Failure, DLQ-Backlog, Bedrock-Throttling, HITL-Backlog, Cost-Anomaly

#### 보안
- **VPC** — 3 private subnet, S3 Gateway endpoint + 8 Interface endpoint (bedrock-runtime, dynamodb, kms, states, secretsmanager, ecr.{dkr,api}, logs). Lambda는 VPC attached (Phase 1 prd; dev는 미부착 허용).
- **IAM 최소 권한** — Lambda별 role, Bedrock은 model ARN 패턴으로 좁힘, KMS는 데이터 클래스 CMK로 좁힘, S3는 bucket+prefix로 좁힘.
- **CloudTrail** — 모든 데이터 이벤트 ON. raw S3 접근 감사 가능.
- **Cognito** — User Pool + 3 그룹 (`ops`, `analyst`, `compliance`); ALB `authenticate-cognito`. `hitl_lib.auth` 가 ALB OIDC JWT 서명(ES256, `kid` 로 공개키 fetch) + JWT `signer` 가 자기 ALB ARN(`ALB_ARN` env)과 일치하는지(region 내 다른 ALB 토큰 거부) 검증, fail-closed (ADR-011).
- **CloudFront + VPC Origin + WAF** (ADR-013) — HITL UI 공개 진입점; viewer ACM 인증서는 us-east-1, ALB HTTPS listener 인증서는 ap-northeast-2.

### 전체 아키텍처 다이어그램

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                              │
│ 외부 STT 생성자 ─▶ S3: stt-raw ─▶ EventBridge: Object Created                │
│                   (KMS-raw)        │                                         │
│                                     ▼                                         │
│                           Step Functions Express                              │
│                           ┌────────────────────────────────────────────┐    │
│                           │ PiiGuard Lambda                              │    │
│                           │   정규식 마스킹 → S3: stt-masked              │    │
│                           │   (KMS-masked)                               │    │
│                           └────────┬─────────────────────────────────────┘    │
│                                    ▼                                          │
│                           ┌────────────────────────────────────────────┐    │
│                           │ Classify Lambda                              │    │
│                           │   Bedrock Opus 4.7 (cache breakpoint ×2)     │    │
│                           │   ➜ {대/중/소 + confidence + reason}         │    │
│                           └────────┬─────────────────────────────────────┘    │
│                                    ▼                                          │
│                           ┌────────────────────────────────────────────┐    │
│                           │ ConfidenceBranch (Choice state)              │    │
│                           │   < 0.80 ─▶ Verify                            │    │
│                           │   ≥ 0.80 ─▶ MarkAutoHigh (Pass state)         │    │
│                           └────┬──────────────────┬─────────────────────┘    │
│                                ▼                  ▼                           │
│                       ┌────────────────┐    (verify 스킵)                     │
│                       │ Verify Lambda   │           │                         │
│                       │ Sonnet 4.6      │           │                         │
│                       │ agree/disagree  │           │                         │
│                       └────────┬───────┘           │                         │
│                                ▼                   ▼                          │
│                           ┌────────────────────────────────────────────┐    │
│                           │ Persist Lambda                               │    │
│                           │   PII 출력 sweep + DDB put_item              │    │
│                           │   (+ Firehose Parquet PR7)                    │    │
│                           │   + EMF 메트릭                                │    │
│                           └────────┬─────────────────────────────────────┘    │
│                                    ▼                                          │
│                           ┌────────────────────────────────────────────┐    │
│                           │ DynamoDB consult-results (3 GSI, TTL)        │    │
│                           │ + S3 Parquet (PR7)                            │    │
│                           └────────────────────────────────────────────┘    │
│                                                                              │
│  DLQ 경로: Classify 실패 ─▶ SendToClassifyDlq (SQS)                          │
│           Persist 실패 ─▶ SendToPersistDlq (SQS)                             │
│                                                                              │
│  읽기 경로 (PR7-8):                                                            │
│     DDB ─▶ Streamlit on Fargate (운영팀 HITL 큐, 검색, 컴플라이언스)            │
│     S3 Parquet ─▶ Athena ─▶ QuickSight (분석팀 대시보드)                       │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 데이터 흐름 요약

`S3 raw .json → EventBridge → SFN Express(PII → Opus → [confidence ≥ 0.80 → Mark | < 0.80 → Sonnet verify] → Persist) → DynamoDB + S3 Parquet → Athena/QuickSight + Streamlit HITL UI`

### 인프라 (Terraform 모듈)

| 모듈 | 목적 | 위치 |
|------|------|------|
| `shared` | VPC, 3 private subnet, 8 VPC endpoint, 공유 SG | `infra/modules/shared/` |
| `storage` | KMS CMK ×4, S3 ×4, DynamoDB + 3 GSI + TTL + PITR, SQS DLQ ×2 | `infra/modules/storage/` |
| `classify-pipeline` | per-Lambda staging-dir 패키징, IAM, log group, Lambda ×4 + cache_warmer(옵션), SFN Express, EventBridge | `infra/modules/classify-pipeline/` |
| `analytics` | Glue, Firehose Parquet, Athena workgroup, QuickSight 데이터셋 | `infra/modules/analytics/` |
| `hitl-ui` | Fargate, internal ALB, Cognito, CloudFront + VPC Origin (ADR-013) | `infra/modules/hitl-ui/` |
| `observability` | CW dashboard, 5개 알람, SNS, Slack relay Lambda | `infra/modules/observability/` |
| `continuous-learning` (Phase 3) | SageMaker Pipelines, Model Registry, Endpoint | _보류_ |

### 핵심 설계 결정 (Why)

- **정확도 > 지연** — 비동기 S3 트리거, SLA 압박 없음. 가장 강한 모델(Opus 4.7) + verify pass + HITL 라우팅 도입 가능.
- **2개 프롬프트 캐시 breakpoint** — 룰 블록(stable) + 분류 트리 블록(xlsx 재생성 시에만 변경). 캐시 적중률 최대화.
- **Pluggable 추론 (`InferenceAdapter` Protocol)** — classify Lambda가 추상 인터페이스를 import하므로, Phase 3에서 `MlAdapter`(KLUE-BERT 캐스케이드)를 SFN/다른 Lambda 변경 없이 끼워넣음 가능.
- **xlsx 원본 코드 보존** — 원본 분류에 있는 `NONEY`/`PAYNENT` 오타는 시스템 식별자이므로 어디서든(코드, 프롬프트, 테스트) 그대로 유지.
- **3중 PII 가드** — 정규식(결정론적·하드 PII) + 프롬프트 R5(LLM 행동) + persist sweep(합성 PII 방어).
- **Per-Lambda staging-dir 패키징** — exclude-list 하나의 zip 대신, Lambda별 `data "external"` 스크립트가 필요한 모듈만 복사. 콜드 스타트 사이즈 + attack surface 감소.
- **DDB ConditionalCheckFailedException → silent skip** — 같은 `callId` 가 다른 `promptVersion` 으로 재처리되면 `persisted=False, skipReason="promptVersion-conflict"` 반환 (DLQ 미진입). DLQ를 진짜 오류 신호로 유지.
- **HITL 낙관적 락 (ADR-011)** — `update_correction`/`update_skip` 이 `ConditionExpression status = hitl-pending` 사용; 동시 검수자 → 선착순 1명 성공, 나머지는 `AlreadyProcessedError`. 감사는 성공 쓰기 후에만 emit.
- **Opus 4.7 temperature 제거 (ADR-014)** — Opus 4.7+ 는 `temperature`/`top_p`/`top_k` 거부(ValidationException); `inferenceConfig` 에 `maxTokens` 만. 결정성은 프롬프트 룰 + output schema 검증으로 담보. 라벨 안정성은 `scripts/eval_prompt.py --runs N` 으로 측정.
- **HITL UI CloudFront + VPC Origin (ADR-013)** — ALB 비노출 공개 진입점; viewer 인증서 us-east-1, origin 인증서 ap-northeast-2.

### 운영

- `docs/runbooks/.template.md` — 런북 템플릿
- 작성된 런북: `bedrock-throttling.md`, `hitl-backlog.md`, `prompt-rollback.md`, `pii-mask-failure.md`, `quicksight-setup.md`
- 셋업 가이드: `docs/operations/atlantis-setup.md`, `docs/operations/github-actions-setup.md`
