---
description: Execute the full test suite (pytest + terraform validate) and report results
allowed-tools: Read, Bash(pytest:*), Bash(python3 -m pytest:*), Bash(terraform fmt:*), Bash(terraform validate:*), Bash(terraform init:*), Bash(ruff check:*), Bash(mypy:*), Glob
---

# Test All

Phase 1 의 전체 검증 스위트 실행 — pytest + ruff + mypy + terraform fmt/validate.

## Step 1: pytest

```bash
python3 -m pytest --no-cov 2>&1 | tail -10
```

기대치: 42 passed (Phase 1 PR1~PR6 baseline). 새 PR 진행 중이면 증가.

## Step 2: Static analysis

```bash
ruff check src tests scripts
ruff format --check src tests scripts
mypy src
```

## Step 3: Terraform

```bash
terraform fmt -recursive -check infra/
terraform -chdir=infra/envs/dev init -backend=false -reconfigure
terraform -chdir=infra/envs/dev validate
```

## Step 4: Report

표시:
- pytest 통과/실패 수
- 실패한 테스트 파일 + 에러 메시지
- ruff/mypy 위반
- terraform validate / fmt 결과

## Error Recovery

### pytest 실패
- 단일 실패: `python3 -m pytest tests/unit/test_<file>.py::<test_name> -v` 로 재현
- module-level adapter 캐시 leak 의심 시 → handler 테스트에 `sys.modules.pop` fixture 확인

### terraform validate 실패
- provider 불일치: `init -backend=false -reconfigure` 재실행
- 변수 누락: `infra/envs/dev/main.tf` 의 `module "classify_pipeline"` 모든 input wired 확인

### moto 관련 오류
- `pip install --user 'moto[s3,dynamodb]>=5.0'` 재설치
- Python 버전 3.9 호스트에서 동작하는지 (`from __future__ import annotations`이 모든 모듈에 있는지)
