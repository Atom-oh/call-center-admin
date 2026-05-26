# `src/prompts/` — Bedrock prompt templates

## Role

분류·검증 Lambda가 시스템 프롬프트에 주입하는 텍스트 산출물. 버전별 디렉토리로 관리하여 회귀 추적·롤백을 단순화한다.

## Versioning

```
src/prompts/
├── v1.0/
│   ├── system_rules.md         — 역할/원칙/R1~R5 룰/출력 스키마 (손으로 작성)
│   ├── taxonomy_tree.json      — xlsx → 213 노드 JSON (생성, git-track)
│   └── taxonomy_tree.md        — 동일 데이터를 markdown 트리로 (디버깅 편의)
├── v1.1/ ...                   — R5 강화 등 minor 버전
└── v2.0/ ...                   — 출력 스키마 변경 같은 major 버전
```

## Rules

### 버전 bump 트리거
- **MAJOR** (`v2.0`): 출력 JSON 스키마 변경, R1~R5 룰 의미가 달라지는 변경, 새 카테고리 (대분류) 추가
- **MINOR** (`v1.1`): 룰 명문화 강화, description 보강, 예외 케이스 명시
- **PATCH** 는 사용 안 함 — 프롬프트 변경은 출력 분포에 영향 주므로 minor 이상

### 갱신 절차
1. 새 디렉토리 `src/prompts/v<N>.<M>/` 생성, 기존 파일 복사
2. `src/lib/prompts.py` 의 `PROMPT_VERSION` 상수 갱신
3. `infra/modules/classify-pipeline/main.tf` 의 `PROMPT_DIR` 환경변수도 갱신 (`/var/task/prompts/v<N>.<M>`)
4. `tests/golden/` 의 골든셋에서 회귀 확인 (`scripts/eval_prompt.py`)
5. canary 10% 24h 후 prod 승격

### taxonomy_tree 재생성
xlsx 원본이 갱신되면 `scripts/parse_taxonomy.py --xlsx 상담어시스트_AWS전달자료.xlsx` 실행. JSON + md 양쪽 모두 커밋.

### 코드 식별자 보존
xlsx의 원본 코드 (`CS_CENTER_CONSULT_TYPE_PAY_NONEY` 등의 typo 포함) **글자 변형 금지**. 시스템 식별자이므로 모델이 변형 시 출력 schema 검증이 실패해야 한다.
