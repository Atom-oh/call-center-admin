# `src/lib/` — 공유 라이브러리 모듈

## Role

Lambda handler가 import해서 쓰는 pure 모듈들의 모음. 각 모듈은 한 가지 책임만 가지며, side-effect (AWS SDK 호출, 파일 I/O) 는 가능한 한 caller(handler)로 미루고 본인은 testable한 입력→출력 함수로 유지한다.

## Key Files

| 파일 | 책임 |
|------|------|
| `taxonomy.py` | xlsx → 213 노드 `TaxonomyNode` 트리 파싱 + serializer (`to_prompt_text`, `to_json`). `effective_description()`이 부모 description을 상속. |
| `pii_regex.py` | 4개 정규식 (계좌·카드·주민·휴대폰) + Luhn 검증 + `MaskStats` 데이터클래스. `mask(text) → (text, stats)`. 적용 순서는 card→rrn→phone→account 고정. |
| `prompts.py` | `PromptBundle` 데이터클래스 + `build_prompt_bundle(rules_md, taxonomy_json)`. 2개 cache breakpoint 구조. `PROMPT_VERSION` 상수가 단일 소스. |
| `output_schema.py` | Bedrock 응답 JSON 파싱·검증. `parse_and_validate(raw, valid_codes) → ClassificationResult`. top-level dict / bool confidence / unknown code / markdown fence 모두 방어. |
| `bedrock_client.py` | `BedrockAdapter` — Bedrock Converse API 래퍼. `cachePoint` 형식 정확히 준수. **Opus 4.7+ 는 `temperature`/`top_p`/`top_k` 미지원**(ValidationException) — `inferenceConfig` 에 `maxTokens` 만 전달. 결정성은 prompt 룰 + output schema 검증으로 담보 (ADR-014). |
| `inference_adapter.py` | `InferenceAdapter` Protocol. Phase 3에서 `MlAdapter`가 같은 인터페이스로 끼어 들어갈 수 있게 추상화. |
| `persistence.py` | `sanitize_text` (PII 정규식 재적용) + `build_ddb_item(event)` (모든 DDB 필드 + TTL + s3:// reference 빌드). |
| `metrics.py` | EMF helper. `emit(metric_name, value, **dims)` → stdout JSON. try/except 격리 (observability가 working path를 깨지 않도록). |

## Rules

- **Pure**: AWS SDK / 파일 I/O / 네트워크 호출 금지. (예외: `bedrock_client.py`는 명백한 wrapper)
- **`from __future__ import annotations`** 모든 파일 첫 import. PEP 604 union 사용.
- **데이터클래스 우선**, Pydantic은 외부 경계 직렬화/검증에만.
- **테스트 1:1 매칭**: 각 모듈은 `tests/unit/test_<name>.py` 와 짝. 새 함수 추가 시 테스트 동시 추가.
- **상수는 모듈 상단**. 예: `PROMPT_VERSION = "v1.0"`, `MASK_PHONE = "[MASKED_PHONE]"`.
- **mypy strict** 통과 필수. `# type: ignore` 사용 시 사유 코멘트 동반.
