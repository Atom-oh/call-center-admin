# `src/lambdas/classify/`

## Role

마스킹된 STT 트랜스크립트를 Amazon Bedrock (Claude Opus 4.7, ap-northeast-2)로 분류한다. `lib/bedrock_client.BedrockAdapter` 를 사용하여 Converse API + 2개 cache breakpoint 구조 호출.

## Input / Output

**Input** (PiiGuard Lambda 출력 → SFN):
```json
{ ..., "maskedBucket": str, "maskedKey": str }
```

**Output**:
```json
{
  "...spread of input...",
  "modelId": "apac.apac.anthropic.claude-opus-4-7-20260101-v1:0",
  "promptVersion": "v1.0",
  "classification": {
    "대": {"code": str, "name": str},
    "중": {"code": str, "name": str},
    "소": {"code": str, "name": str},
    "confidence": float,
    "reason": str,
    "alternativesConsidered": [{"code": str, "why_rejected": str}, ...]
  }
}
```

## Env vars

- `MODEL_ID` — `apac.anthropic.claude-opus-4-7-20260101-v1:0`
- `PROMPT_DIR` — `/var/task/prompts/v1.0` (Lambda 런타임), 로컬 테스트 시 `src/prompts/v1.0`

## Rules

- 시스템 프롬프트는 `system_rules.md` + `taxonomy_tree.json` 두 블록. 각 블록 뒤에 `{"cachePoint": {"type": "default"}}` (Bedrock Converse 정확한 형식).
- temperature=0.0, maxTokens=1024.
- 모델 출력 JSON은 `lib.output_schema.parse_and_validate` 가 검증 — 마크다운 fence 제거, top-level dict 강제, unknown code 거부, confidence [0,1] + bool 거부.
- Bedrock 예외는 throw — SFN의 Retry/Catch가 처리 (Throttling/ServiceUnavailable 포함).
- 콜드 스타트 비용 절감: `_RULES`, `_TREE`, `_BUNDLE`, `_ADAPTER`, `_s3` 모두 module-level.
- Phase 3에서 ML cascade가 들어올 때, classify handler가 `MlAdapter` 를 먼저 호출하고 confidence 임계 미달 시 Bedrock으로 폴백할 수 있도록 `InferenceAdapter` 추상화 활용.
