# `src/hitl_ui/` — HITL 검수 UI (Streamlit on Fargate)

## Role

운영/분석/컴플라이언스 팀이 분류 결과를 검수·교정·검색·감사하는 **Streamlit 멀티페이지 앱** (ADR-011). classify 파이프라인이 `status=hitl-pending` 으로 남긴 통화를 사람이 확인해 라벨을 확정한다. 폐쇄 루프의 HITL 구간 — 여기서 확정된 교정 라벨이 Phase 3 ML 학습셋(ADR-001)의 baseline 이 된다.

- **인증**: ALB `authenticate-cognito` 가 OIDC 헤더(`x-amzn-oidc-data`, ES256 JWT)를 주입 → `hitl_lib.auth` 가 **서명 검증** 후 그룹 기반 RBAC.
- **fronting**: CloudFront + VPC Origin → Private ALB → ECS Fargate (ADR-013). UI 컨테이너는 사설 서브넷.
- **SFN 밖**: 분류 파이프라인(Step Functions)과 분리된 상시 웹 서비스.

## Key Files

```
streamlit_app.py     — 진입점. set_page_config + 전체 그룹 require_group 게이트. pages/ 자동 등록.
Dockerfile           — python:3.12-slim, EXPOSE 8501, CMD streamlit run …/streamlit_app.py
requirements.txt     — streamlit + boto3 + PyJWT[crypto] (서명 검증용)
hitl_lib/            — auth(JWT 검증) / audit(5년 감사 로그) / ddb_access(GSI 쿼리 + 낙관적 락)  → 자체 CLAUDE.md
pages/               — 1_review_queue(ops) / 2_search(ops·analyst) / 3_compliance(compliance)  → 자체 CLAUDE.md
```

## Rules

- **모든 페이지는 `require_group([...])` 를 최상단에서 호출** — Streamlit 멀티페이지는 URL 직접 접근이 가능하므로 페이지마다 RBAC 를 재확인한다. `streamlit_app.py` 의 게이트만으로는 부족.
- **DDB 쓰기는 `hitl_lib.ddb_access` 경유만** — 페이지가 boto3 로 직접 `put_item` 하지 않는다 (낙관적 락 + 감사 일관성). 예외: 3_compliance 의 S3 presigned URL 은 boto3 직접 호출 OK.
- **PII**: 교정/검수 경로는 `reason`/`alternativesConsidered` 를 **수정하지 않는다** (ADR-003 — 이 컬럼들은 classify/persist 가 이미 sanitize). 원본 STT 다운로드(3_compliance)는 CloudTrail Data Events 로 감사.
- **모델 무관**: 이 앱은 Bedrock 을 호출하지 않는다 — DDB 읽기/쓰기 + S3 presign 만. classify 모델 버전(Opus 4.7)과 독립.
- **로컬 개발**: `LOCAL_DEV=1` 시 `auth` 가 `dev-user` + 3개 그룹 전체를 반환하고 JWT 검증을 우회 (데스크톱/단위 테스트 전용 — 컨테이너/운영에서는 절대 설정 금지).
- 인프라 정의는 `infra/modules/hitl-ui/` (ALB/ECS/Cognito/CloudFront). 이미지 태그는 commit SHA 로 불변 주입 (`var.hitl_image_tag`).
