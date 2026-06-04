# `src/hitl_ui/hitl_lib/` — HITL UI 공유 라이브러리

## Role

Streamlit 페이지가 import 하는 3개 핵심 모듈: 인증(`auth`), 감사(`audit`), 데이터 접근(`ddb_access`). 페이지는 UI 렌더링만 하고 보안/영속/감사 로직은 전부 여기로 위임한다. `mypy --strict` 대상.

## Key Files

| 파일 | 책임 |
|------|------|
| `auth.py` | ALB `x-amzn-oidc-data` (ES256 JWT) **서명 검증** 후 `current_user()`/`current_groups()`/`require_group()` 제공. JWT 헤더의 `kid` 로 ALB region 공개키(`public-keys.auth.elb.{region}.amazonaws.com/{kid}`)를 `lru_cache` fetch 해 검증. PyJWT/cryptography 없고 `LOCAL_DEV≠1` 이면 **fail-closed**(빈 claims). |
| `audit.py` | `emit_audit(action, user, call_id, **extras)` — CloudWatch Logs 감사 레코드 1건 기록 (ADR-012 5년 보존). **절대 raise 안 함** (best-effort): put_log_events 실패 시 `AUDIT_FALLBACK` 로 stdout fallback. UI 흐름을 깨지 않는다. |
| `ddb_access.py` | 검수 큐/검색 GSI 쿼리 + `update_correction`/`update_skip` (낙관적 락). `AlreadyProcessedError` 정의. |

## Rules

- **auth 는 fail-closed**: 서명 검증 실패·kid 누락·공개키 fetch 실패 → 빈 dict → `current_groups()=[]` → `require_group()` 차단. fail-open(미검증 통과) 금지 (CWE-754). `LOCAL_DEV=1` 만 미검증 디코드 허용.
- **낙관적 락 (ADR-011)**: `update_correction`/`update_skip` 은 `ConditionExpression="#s = :pending"` (status 가 `hitl-pending` 일 때만 쓰기) → 동시 검수 시 **선착순 1명만 성공**, 나머지는 `ConditionalCheckFailedException` → `AlreadyProcessedError(call_id)` 로 변환. 페이지는 이를 잡아 경고 후 새로고침.
- **감사는 성공 쓰기 이후에만**: `emit_audit` 를 `update_item` 성공 다음에 호출 — 거부된(락 실패) 쓰기는 감사 레코드를 남기지 않는다 (`test_rejected_lock_emits_no_audit` 가드).
- **ADR-003**: `update_correction` 은 `reason`/`alternativesConsidered` 컬럼을 만지지 않는다 (PII 재노출 방지).
- **ADR-008**: GSI **index 명은 ASCII** (`category-daecode-classifiedAt-index`) 이지만 KeyConditionExpression 의 attribute 는 한글(`category_대code`) — placeholder(`#daecode`)로 브리지.
- **테스트**: `tests/unit/test_hitl_ddb_access.py` (낙관적 락 + 감사), `tests/unit/test_hitl_auth.py` (서명 검증/fail-closed). moto + 직접 seed.
