# `src/lambdas/persist/`

## Role

SFN 마지막 단계. classify(+verify) 결과를 DynamoDB `consult-results` 에 idempotent하게 적재. Phase 1 Firehose Parquet은 미연결 (PR7 진입 시 wire).

## Input / Output

**Input** (Verify Lambda 출력 또는 MarkAutoHigh Pass state 출력):
```json
{
  callId, agentId, startedAt, durationSec,
  rawBucket, rawKey, maskedBucket, maskedKey,
  modelId, promptVersion,
  classification: {...},
  verified, status, modelPath
}
```

**Output**:
```json
{ "...spread of input...", "persisted": True }     // 정상
{ "...spread of input...", "persisted": False, "skipReason": "promptVersion-conflict" }  // 동일 callId가 다른 promptVersion으로 재처리될 때
```

## Env vars

- `DDB_TABLE` — `callcenter-<env>-consult-results`
- `FIREHOSE_NAME` — 빈 문자열이면 Firehose put 스킵 (PR7에서 채움)

## Rules

- **Idempotency**: `put_item` 의 `ConditionExpression="attribute_not_exists(callId) OR promptVersion = :pv"` — 같은 callId 가 같은 promptVersion 으로는 재기록 OK (SFN retry 안전), 다른 promptVersion 으로는 거부됨.
- **ConditionalCheckFailedException → silent skip** + `classification.skippedExisting` 메트릭. SFN DLQ에 가지 않음. promptVersion drift 추적용 시그널.
- **3차 PII sweep**: `lib.persistence.sanitize_text` 가 `reason` / `alternativesConsidered.why_rejected` 에 정규식 재적용 (LLM이 만든 합성 PII 차단). 적용 후 길이 cap (2000 / 500 char).
- **DDB float → Decimal**: 모든 float는 `_to_decimal` 로 변환 (DDB는 float 불가).
- **DDB 컬럼 일관성**: `infra/modules/storage/main.tf` 의 attribute 명과 정확히 일치 (`category_대code`, `category_중code`, `category_소code`, `callId`, `agentId`, `status`, `classifiedAt`).
- **KMS scope**: persist Lambda IAM은 `kms_ddb_arn` 만 사용 (다른 CMK 접근 불가).
- **modelPath None 필터**: `event.get("modelPath", [event.get("modelId")])` 결과에서 None 항목 제거 — 다운스트림 분석이 None 처리 안 해도 되도록.
