# Architecture Decision Records

Phase 1 (콜센터 STT 자동 분류 시스템) 의 10 개 ADR. 각 ADR 은 의무적으로 Mermaid 아키텍처 흐름 다이어그램을 포함한다 (프로젝트 규칙).

## Index

| ADR | 제목 | 상태 | 주요 영역 |
|---|---|---|---|
| [ADR-001](ADR-001-pluggable-inference-adapter.md) | Pluggable InferenceAdapter Protocol | Accepted | LLM ↔ ML 추론 교체 (Phase 3) |
| [ADR-002](ADR-002-two-breakpoint-prompt-cache.md) | Bedrock two-breakpoint prompt cache | Accepted | 비용 최적화 (~$50/day) |
| [ADR-003](ADR-003-three-layer-pii-guard.md) | Three-layer PII guard | Accepted | 보안 / 데이터 보호 |
| [ADR-004](ADR-004-preserve-xlsx-code-identifiers.md) | xlsx 코드 식별자(NONEY/PAYNENT) 보존 | Accepted | 분류 체계 / 다운스트림 호환 |
| [ADR-005](ADR-005-per-lambda-staging-dir-packaging.md) | per-Lambda staging-dir Terraform packaging | Accepted | IaC / 패키징 |
| [ADR-006](ADR-006-kms-data-class-separation.md) | KMS 데이터 클래스 분리 (4 CMK) | Accepted | 보안 / IAM |
| [ADR-007](ADR-007-sfn-express-orchestration.md) | Step Functions Express orchestration | Accepted | 오케스트레이션 |
| [ADR-008](ADR-008-korean-ddb-attribute-ascii-gsi-name.md) | 한국어 DDB 속성명 + ASCII GSI 명 | Accepted | DDB 스키마 |
| [ADR-009](ADR-009-atlantis-for-terraform-deployment.md) | Atlantis 로 Terraform 처리 | Accepted | 배포 / CI |
| [ADR-010](ADR-010-global-bedrock-cris.md) | global Bedrock CRIS | Accepted | Bedrock 통합 / latency |
| [ADR-011](ADR-011-hitl-ui-streamlit-on-fargate.md) | HITL UI = Streamlit on Fargate + ALB authenticate-cognito | Accepted | UI / Fargate / Cognito |
| [ADR-012](ADR-012-audit-log-retention-5-years.md) | HITL 감사 로그 5년 보존 (전자금융거래법 §22) | Accepted | 컴플라이언스 / 비용 |

## 작성 규칙

1. 새 ADR 은 `.template.md` 복사 후 작성
2. **Mermaid 아키텍처 흐름 다이어그램 필수** (`## Architecture Flow` 섹션)
3. Date 는 결정 시점. 후속 재문서화는 본문에 `(재문서화 YYYY-MM-DD)` 병기.
4. Status 변경 시 (Deprecated / Superseded) 본 INDEX 와 ADR 본문 둘 다 업데이트
5. 관련 ADR 간 cross-link 는 `[[ADR-NNN-slug]]` 표기

## 관련 문서

- 설계 spec: `docs/superpowers/specs/2026-05-22-callcenter-stt-classification-design.md`
- 구현 plan: `docs/superpowers/plans/2026-05-22-phase1-callcenter-classification.md`
- 운영 docs: `docs/operations/`
