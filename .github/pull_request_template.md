# PR 요약

<!-- 본 PR이 무엇을, 왜 변경하는지 2-3 문장. -->

## 변경 사항

<!-- 주요 변경점 bullet. 예시: -->
- [ ] feat / fix / docs / refactor / test / chore / ci 분류
- [ ] Lambda handler / Terraform 모듈 / 분류 트리 / 프롬프트 / 운영 문서 중 어디에 변경이 있는지

## 검증

<!-- 어떻게 확인했는지. 가능한 명령어를 그대로. -->
- [ ] `pytest --no-cov` 통과 (현재 baseline 42개)
- [ ] `ruff check src tests scripts` 클린
- [ ] `mypy src` 클린
- [ ] `terraform fmt -recursive -check infra/` 클린
- [ ] `terraform -chdir=infra/envs/dev validate` Success

## 관련 plan / spec / ADR

<!-- docs/ 안의 어떤 문서가 이 변경의 근거인지 -->
- spec: `docs/superpowers/specs/2026-05-22-callcenter-stt-classification-design.md` §...
- plan: `docs/superpowers/plans/...md` 의 PR 번호
- ADR (있다면): `docs/decisions/ADR-NNN-*.md`

## 영향

<!-- 다음 중 어떤 면에 영향이 있는지 -->
- [ ] DDB 스키마 / GSI (apply 시 destructive 가능)
- [ ] Bedrock 프롬프트 버전 (`PROMPT_VERSION` bump 필요?)
- [ ] IAM 권한 범위
- [ ] KMS 키 분리 / 정책
- [ ] SFN ASL state machine 정의
- [ ] EventBridge 룰 / 트리거
- [ ] Lambda 패키징 (staging-dir 추가/변경)
- [ ] 비용 증감 (Bedrock 호출, GPU 인스턴스, Lambda 메모리 등)

## 체크리스트 — 새 ADR이 동봉되었다면

- [ ] `docs/decisions/ADR-NNN-*.md` 작성 (다음 번호로 증가)
- [ ] **Mermaid 다이어그램이 포함됨** (필수, 본 프로젝트 컨벤션)
- [ ] Before / After 흐름 비교 또는 단일 상태/시퀀스 다이어그램 명시

## 자동화

- **PR-Review**: Claude (Bedrock Opus 4.7) 가 본 PR을 자동 리뷰하여 코멘트로 게시
- **CI**: ruff + mypy + pytest + terraform fmt/validate + tfsec
- **Terraform Plan**: `infra/**` 변경 시 `terraform plan` 결과 PR 코멘트
- **Terraform Apply**: main 머지 시 `dev` 환경 자동 apply (`environment: dev` 보호 룰 적용)

## Definition of Done

- [ ] CI 전체 통과
- [ ] Claude 리뷰의 Critical / Important 이슈 모두 해결
- [ ] terraform plan 검토 완료 (변경 사항이 의도와 일치)
- [ ] 적어도 1명의 사람 리뷰어 승인
- [ ] 머지 후 `terraform apply` 워크플로우 성공 확인
