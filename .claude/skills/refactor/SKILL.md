# Refactor Skill

Refactor existing code to improve quality without changing behavior. Especially load-bearing for this project: Lambda handlers have module-level caching, Terraform modules have downstream PRs depending on input/output shapes.

## Principles
- 구조 개선, 행동 보존
- Single Responsibility (예: `pii_regex.py` = pure regex+Luhn, `pii_guard/handler.py` = S3 I/O)
- DRY (예: per-Lambda staging-dir 패턴은 4개 Lambda에 공유)
- 작은 점진 단계 + 단계별 검증 (pytest, `terraform validate`)

## Process

### 1. Analysis
- 타깃 코드와 테스트 식별 (pytest는 `tests/unit/test_<module>.py`)
- 모든 caller·의존성 매핑
- 테스트 커버리지 확인 (없으면 추가 먼저)
- **InferenceAdapter / Module 변수 reservation**: Phase 3 또는 후속 PR에서 기다리는 인터페이스를 깨지 않는지 확인

### 2. Plan
사용자에게 리팩터링 계획 제시:
- 변경되는 것 / 변경되지 **않는** 것 (행동 보존)
- 위험도 (낮음/중간/높음)
- DDB 스키마 / GSI / Bedrock 프롬프트 버전 같은 **불가역 영향**이 있으면 명시
- Terraform `apply` 후 변경하면 데이터 손실/리소스 재생성 발생하는 항목 (예: DDB 인덱스 이름)은 사전 alarm

### 3. Execute
- 작은 검증 가능 단계로 나눠 수행
- 단계별 `pytest --no-cov`, `ruff check`, `mypy`, `terraform fmt+validate`
- 커밋 단위 atomic, `refactor(scope): ...` prefix

### 4. Verify
- 기존 테스트 전부 pass (42개 baseline)
- 행동 변화 없음 (특히 SFN execution payload 모양, DDB record shape)
- 리팩터링 목표 달성 확인
