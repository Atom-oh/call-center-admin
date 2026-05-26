# `src/lambdas/verify/`

## Role

Classify Lambda 의 결과 신뢰도가 낮을 때 (`confidence < 0.80`) Step Functions ConfidenceBranch에 의해 호출. Bedrock Sonnet 4.6 으로 같은 마스킹 트랜스크립트를 다시 분류하고, primary (Opus) 와 secondary (Sonnet) 의 대/중/소 코드를 비교한다.

## Input / Output

**Input** (Classify Lambda 출력 → SFN ConfidenceBranch < 0.80 → Verify):
```json
{ ..., "modelId": str, "promptVersion": str, "classification": {...} }
```

**Output**:
```json
{
  "...spread of input...",
  "verifiedBy": "anthropic.claude-sonnet-4-6-20260101-v1:0",
  "verifyResult": {...full ClassificationResult from Sonnet...},
  "verified": "auto-confirmed" | "hitl-pending",
  "status": "confirmed" | "hitl-pending",
  "modelPath": [primary_model_id, verify_model_id]
}
```

## Env vars

- `VERIFY_MODEL_ID` — `anthropic.claude-sonnet-4-6-20260101-v1:0`
- `PROMPT_DIR` — classify와 동일 (`v1.0`).

## Rules

- 합의 판정: 대/중/소 **세 코드 모두 일치**해야 `auto-confirmed`. 하나라도 다르면 `hitl-pending`.
- Hard-fail on missing `event["modelId"]` — verify는 classify 후에만 호출되어야 하므로 `event.get("modelId")` 가 `None` 이면 contract violation. 직접 인덱싱.
- `_assert_primary_shape(primary)` 으로 Bedrock 비용 청구 전에 input schema drift를 잡음.
- 출력 `agreement` 메트릭 dim은 `"agree"` / `"disagree"` (CloudWatch Insights 가독성).
- `_VERIFY_MODEL_ID` 가 IAM Bedrock invoke 권한과 분리된 패턴(`claude-sonnet-4-*`)으로만 스코프 — classify(`claude-opus-4-*`)와 cross-purpose 방지.
- 테스트는 module-level `_ADAPTER` 캐시 우회 위해 fixture에서 `sys.modules.pop("lambdas.verify.handler", None)` 필수.
