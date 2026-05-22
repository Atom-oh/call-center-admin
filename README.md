# call-center-admin

콜센터 STT 자동 분류 시스템 (Phase 1).

## 빠른 시작

```bash
python -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"
pytest
```

## 분류 트리 재생성

xlsx 원본이 갱신되었을 때 분류 트리 산출물(`src/prompts/v1.0/taxonomy_tree.{json,md}`)을 재생성:

```bash
python3 scripts/parse_taxonomy.py --xlsx 상담어시스트_AWS전달자료.xlsx
```

산출물은 git에 커밋되어 있으며 xlsx가 바뀔 때마다 재생성·재커밋해야 한다.

## 문서

- 설계서: `docs/superpowers/specs/2026-05-22-callcenter-stt-classification-design.md`
- 구현 계획: `docs/superpowers/plans/`
- 운영 런북: `docs/runbooks/`
