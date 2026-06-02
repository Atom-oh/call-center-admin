# `src/lambdas/cache_warmer/`

## Role

EventBridge cron 으로 주기 호출되어 Bedrock **prompt cache 를 워밍** (ADR-002). classify Lambda 와 **동일한 2-breakpoint system 블록**(system_rules + taxonomy_tree) 을 **동일 MODEL_ID** 로 호출하여 cache key 를 적중 → cold-cache input token 비용 spike 완화. SFN 파이프라인 밖의 독립 Lambda.

**OPTIONAL / default-OFF**: Terraform `var.enable_cache_warming` (default `false`) 으로 게이트. false 면 리소스 0개 / 비용 0.

## Input / Output

**Input**: EventBridge scheduled event (무시). **Output**:
```json
{ "warmed": true, "modelId": "global.anthropic.claude-opus-4-7",
  "promptVersion": "v1.0", "cacheReadInputTokens": <int> }
```

## Env vars

- `MODEL_ID` — classify 와 동일해야 cache key 일치 (`global.anthropic.claude-opus-4-7`)
- `PROMPT_DIR` — `/var/task/prompts/v1.0`

## Rules

- **cache key 일치가 핵심** (ADR-002): `BedrockAdapter.warm()` 이 `_build_system()` 을 classify 와 공유. system 블록 / MODEL_ID / PROMPT_DIR 이 classify 와 어긋나면 다른 키를 워밍 → 효과 0.
- `warm()` 은 `parse_and_validate` 미수행 — 워밍 핑은 유효한 분류 결과가 아님. `maxTokens=1`.
- IAM 최소권한 (ADR-006): `bedrock:InvokeModel` (opus inference-profile ARN) + 자기 log group 만. **KMS/S3/DDB 권한 없음**.
- ADR-014: `inferenceConfig` 에 temperature 없음 (`warm()` 도 maxTokens 만).
- 패키징: 다른 Lambda 와 동일 staging-dir 패턴 (`data "external" "cache_warmer_stage"` + `archive_file`). lib/ + prompts/ 필요 (verify/classify 와 동일).
- Bedrock 예외는 throw — cron 이 다음 tick 에 재시도. (SFN 없음 → Lambda 실패는 CW 로그/알람.)
