# Sync Docs Skill

Synchronize project documentation with current code state.

## Actions

### 1. Quality Assessment
각 CLAUDE.md (root + module별)을 0-100으로 점수:
- Commands/workflows (20 pts)
- Architecture clarity (20 pts)
- Non-obvious patterns (15 pts)  ← 본 프로젝트 핵심 (NONEY 오타 보존, 한글 boundary 등)
- Conciseness (15 pts)
- Currency (15 pts)
- Actionability (15 pts)

Anti-pattern 감점:
- 500 줄 초과 (-15)
- vague 지시 (-10)
- 중복 docs (-10)
- 테스트 가이드 없음 (-10)
- secret 포함 (-20)

### 2. Root CLAUDE.md Sync
- Overview, Tech Stack, Conventions, Key Commands 갱신
- 명령어는 실제 `pyproject.toml`, `scripts/`, `Makefile` 과 일치하는지 검증
- **본 프로젝트 특이사항**: STATUS.md 의 현재 PR 진척 상황을 반영

### 3. Architecture Doc Sync
- `docs/architecture.md` 갱신
- 새 컴포넌트, 데이터 흐름, 인프라 변경 반영
- **Mermaid 다이어그램 필수** (특히 SFN state machine, EventBridge 데이터 흐름)
- ADR 갱신 시도 Mermaid 다이어그램 필수 — `docs/decisions/.template.md` 참고

### 4. Module CLAUDE.md Audit
- `src/` + `infra/modules/` 아래 모든 모듈 스캔
- CLAUDE.md 없는 모듈은 생성
- 기존 CLAUDE.md 가 outdated 면 갱신
- 본 프로젝트는 `src/lambdas/{pii_guard,classify,verify,persist}/` 각각 + `src/lib/` + `src/prompts/` 모듈 단위
- Score 출력

### 5. ADR and Runbook Audit
- 최근 커밋에서 미문서화 아키텍처 결정 검출 (예: Bedrock 모델 선택 변경, SFN retry policy 변경)
- 런북 커버리지 점검 (`docs/runbooks/` — bedrock-throttling, hitl-backlog, prompt-rollback, pii-mask-failure 등)
- stale ADR / 오래된 런북 flag

### 6. README.md Sync
- 프로젝트 구조 섹션을 실제 디렉토리 레이아웃과 일치시킴
- 영어/한국어 양쪽 동일 구조 유지
- shields.io 배지 갱신 (license, Python 3.12, language toggle 등)

### 7. Report
점수 before/after, 발견된 anti-pattern, 모든 변경 list 출력.
