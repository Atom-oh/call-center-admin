# Release Skill

본 프로젝트의 릴리즈는 Phase 1 cutover 이전까지는 git tag + CHANGELOG 갱신 위주, Phase 1 prd 진입 후엔 Terraform stg→prd promotion + Lambda 코드 zip 배포까지 포함된다.

## Procedure

### 1. Pre-release Checks
- 워킹 트리 클린: `git status`
- 모든 단위 테스트 pass: `pytest`
- `terraform fmt -recursive -check infra/` clean
- `terraform -chdir=infra/envs/dev validate` Success
- 골든셋 평가 (Bedrock 호출 가능한 환경에서): `python scripts/eval_prompt.py --skip-tbd` → 대분류 정확도 ≥ 80%

### 2. Determine Version
- 마지막 태그 이후 변경 확인: `git log $(git describe --tags --abbrev=0 2>/dev/null || git log --reverse --format=%H | head -1)..HEAD --oneline`
- Semver:
  - **MAJOR**: SFN ASL state 추가/제거 또는 DDB 스키마 변경 (apply 시 destructive)
  - **MINOR**: 새 Lambda, 새 Terraform 모듈, 프롬프트 버전 bump (`PROMPT_VERSION` 변경)
  - **PATCH**: 버그 fix, regex 강화, 테스트 추가만

### 3. Update Changelog
- `CHANGELOG.md` 의 `[Unreleased]` 섹션을 새 버전 헤더로 승격
- 분류: Added / Changed / Deprecated / Removed / Fixed / Security (Keep a Changelog 컨벤션 — 영어 헤더 유지)
- 한국어 섹션도 동일 구조 유지 (`# 한국어`)
- 본 프로젝트 특이 카테고리: **Phase progress** (PR1~PR10 마일스톤), **Prompt versions** (`v1.0` → `v1.1` 등)

### 4. Create Release
- `pyproject.toml` 의 `version` 갱신
- `git tag -a vX.Y.Z -m "Release vX.Y.Z — <one-line summary>"`
- (Phase 1 prd 진입 후) GitHub Release notes 자동 생성

### 5. Deploy (Phase 1 prd 진입 후 — 기본은 GitHub Actions OIDC)
- `gh workflow run deploy-stg.yml --ref vX.Y.Z` → e2e smoke
- 통과 시 `gh workflow run deploy-prd.yml --ref vX.Y.Z` (수동 승인 게이트)

### 6. Summary
- 버전 bump 표시
- 핵심 변경 사항 나열 (특히 SFN state machine 변경 / 프롬프트 버전 / IAM 변경)
- 다음 단계 (push tag, 운영 모니터링, 골든셋 재평가)
