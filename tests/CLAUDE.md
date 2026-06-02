# `tests/`

## Role

`pytest` 단위 + 통합 테스트 + golden set scaffold. 42 baseline 테스트 모두 통과 상태 유지.

## Structure

```
tests/
├── conftest.py              — repo_root, xlsx_path fixture (NFD 파일명 대응)
├── unit/                    — 단위 테스트 (8 모듈 × 평균 5 test)
│   ├── test_taxonomy.py
│   ├── test_pii_regex.py
│   ├── test_output_schema.py
│   ├── test_prompts.py
│   ├── test_persistence.py
│   ├── test_metrics.py
│   ├── test_pii_guard_handler.py
│   ├── test_classify_handler.py
│   ├── test_verify_handler.py
│   └── test_persist_handler.py
├── integration/
│   ├── __init__.py
│   └── test_sfn_definition.py  — SFN ASL 정의 정적 구조 grep
├── golden/
│   ├── samples.json         — 5행 scaffold (g001 real, g002-g005 TBD)
│   ├── expected_labels.json — unused (label은 samples.json에 inline)
│   ├── README.md
│   └── eval-history.csv     — eval_prompt.py 누적 결과 (CI artifact)
├── hooks/                   — (PR 진행 시 추가) harness 검증 스크립트
├── structure/               — (PR 진행 시 추가) 매니페스트 검증 스크립트
├── fixtures/                — (PR 진행 시 추가) 시크릿 패턴 샘플
└── run-all.sh               — TAP-style 테스트 러너 (PR 진행 시 추가)
```

## Rules

### pytest 컨벤션
- `pytest --no-cov` 빠른 실행, `pytest` 가 기본 coverage 포함 (pyproject.toml addopts에 `--cov=src`)
- 단일 파일: `pytest tests/unit/test_<name>.py -v`
- 단일 테스트: `pytest tests/unit/test_<name>.py::test_<func> -v`

### Lambda handler 테스트 패턴
- `moto.mock_aws` 데코레이터로 AWS 리소스 mock
- `boto3.client("dynamodb")` + `create_table` → handler import → 실행 → 결과 검증
- Bedrock 호출은 `MagicMock + patch("lib.bedrock_client.boto3.client")` — 실제 호출 발생 0건
- module-level `_ADAPTER` 캐시 leak 방지: env fixture에서 `sys.modules.pop("lambdas.<name>.handler", None)`
- 핸들러는 절대 module scope에서 import 금지 (fixture 효과 무효화), **테스트 함수 안에서** import

### 골든셋
- 5행 scaffold 상태. real label은 g001만.
- 손 라벨링 50~100건 누적은 W2 deferred (분석팀 또는 외주 책임).
- `python scripts/eval_prompt.py --skip-tbd` 가 TBD 행을 자동 스킵.
- `python scripts/eval_prompt.py --runs 5` → per-row (대/중/소) 라벨 안정성 측정, `tests/golden/variance-report.csv` 산출 (ADR-014 temperature 제거 후 변동성 검증). 하니스 로직 단위 테스트는 `tests/unit/test_eval_prompt.py`.
- CI에서 매 PR마다 자동 평가 + 회귀 -2%p시 fail (PR10에서 GitHub Actions 추가).

### TDD 원칙
1. 실패하는 테스트 먼저 작성
2. `pytest tests/unit/test_<name>.py -v --no-cov` → FAIL 확인
3. 구현
4. 다시 실행 → PASS 확인
5. 인접 회귀 (전체 `pytest`) 확인
6. 커밋

### Coverage 정책
- `pyproject.toml` 의 `addopts = "--cov=src --cov-report=term-missing"` 활성
- 로컬에서 빠른 반복 시 `--no-cov`
- CI에서는 coverage 포함하고 thresholds 미정 (Phase 1 베이스라인 수립 단계)
