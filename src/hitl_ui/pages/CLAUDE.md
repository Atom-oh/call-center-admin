# `src/hitl_ui/pages/` — Streamlit 멀티페이지

## Role

Streamlit 의 `pages/` 규약으로 사이드바에 자동 등록되는 검수 화면들. 파일명 숫자 접두사가 정렬 순서. 각 페이지는 **자체 `require_group()`** 으로 RBAC 를 재확인한다 (URL 직접 접근 방어).

## Key Files

| 페이지 | 허용 그룹 | 역할 |
|--------|----------|------|
| `1_review_queue.py` | `ops` | `hitl-pending` 큐 검수: 분류 확정 / 교정 저장 / 스킵. 3개 콜백 모두 `AlreadyProcessedError` 를 잡아 "이미 처리됨" 경고 후 `st.rerun()`. |
| `2_search.py` | `ops`, `analyst` | 상담원ID 또는 **대분류 코드**로 검색 (GSI 쿼리). 코드 예시는 verbatim 식별자(`…PAY_NONEY`) — ADR-004. |
| `3_compliance.py` | `compliance` | 원본 STT raw S3 객체의 5분 presigned URL 발급. URL 반환 **전에** `emit_audit("compliance.presigned_url", …)` (클릭 안 해도 의도 기록). S3 GetObject 는 CloudTrail Data Events 로 감사. |

## Rules

- **페이지 최상단 첫 호출 = `require_group([...])`** — 게이트 통과 못 하면 `st.error` + `st.stop()`. `streamlit_app.py` 의 전역 게이트에 의존하지 말 것.
- **쓰기 경로는 `hitl_lib.ddb_access` 만** (낙관적 락 + 감사). `1_review_queue` 의 교정/스킵은 `update_correction`/`update_skip` 경유.
- **`AlreadyProcessedError` 는 반드시 처리**: 동시 검수자 충돌은 정상 흐름 — crash 아닌 경고+새로고침으로 처리.
- **ADR-003**: 교정 UI 는 `reason` 을 노출/편집하지 않는다. 코드 라벨만 교정.
- **ADR-004**: 코드 입력/표시에서 오타 식별자(`NONEY`/`PAYNENT`)를 절대 "교정"하지 말 것 — 다운스트림 join key.
- 신규 페이지 추가 시 숫자 접두사 부여 + `require_group` + (쓰기 시) `ddb_access` 경유 패턴을 따른다.
