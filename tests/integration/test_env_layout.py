"""infra/envs/{dev,stg,prd}/ 디렉토리 구조 / drift 검증 (spec §6.1).

PR10 의 핵심 invariant: stg/prd 가 dev 와 동일 module set 을 호출하고
backend key 만 분리되어 있는지. 어느 한 env 에 module 이 누락되면 fail.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent.parent
ENVS = ("dev", "stg", "prd")
REQUIRED_FILES = ("backend.tf", "main.tf", "outputs.tf", "variables.tf")
REQUIRED_MODULES = (
    "shared",
    "storage",
    "analytics",
    "classify_pipeline",
    "observability",
    "hitl_ui",
)


def _env_path(env: str) -> Path:
    return REPO_ROOT / "infra" / "envs" / env


@pytest.mark.parametrize("env", ENVS)
def test_env_has_required_files(env: str) -> None:
    """spec §2.1: every env directory must have backend / main / outputs / variables."""
    for fname in REQUIRED_FILES:
        path = _env_path(env) / fname
        assert path.exists(), f"missing required file: infra/envs/{env}/{fname}"


def test_backend_keys_are_environment_separated() -> None:
    """spec §2.1: backend tfstate keys must be unique per env to avoid state collision."""
    keys: dict[str, str] = {}
    for env in ENVS:
        backend = (_env_path(env) / "backend.tf").read_text(encoding="utf-8")
        match = re.search(r'key\s*=\s*"([^"]+)"', backend)
        assert match, f'infra/envs/{env}/backend.tf has no `key = "..."` line'
        keys[env] = match.group(1)
    # All keys must be distinct.
    assert len(set(keys.values())) == len(keys), f"backend keys collide across envs: {keys!r}"
    # Each key must include the env name (envs/<env> prefix; dev uses
    # `envs/dev.tfstate` form, allow either flavor) — drift guard.
    for env, key in keys.items():
        assert f"envs/{env}" in key, f"env {env} backend key does not mention env: {key!r}"


@pytest.mark.parametrize("env", ("stg", "prd"))
def test_env_variable_default_matches_directory_name(env: str) -> None:
    """spec §2.2: the `env` variable default must match the directory name."""
    variables = (_env_path(env) / "variables.tf").read_text(encoding="utf-8")
    pattern = re.compile(r'variable\s+"env"\s*\{[^}]*default\s*=\s*"' + env + r'"', re.DOTALL)
    assert pattern.search(variables), (
        f'infra/envs/{env}/variables.tf: env variable default must be "{env}"'
    )


@pytest.mark.parametrize("env", ENVS)
def test_main_tf_calls_required_modules(env: str) -> None:
    """spec §2.1: every env must call the same module set (no drift)."""
    main_tf = (_env_path(env) / "main.tf").read_text(encoding="utf-8")
    for module in REQUIRED_MODULES:
        # Match either `module "shared"` or `module "classify_pipeline"` etc.
        pattern = rf'module\s+"{module}"\s*\{{'
        assert re.search(pattern, main_tf), (
            f"infra/envs/{env}/main.tf does not call module {module!r}"
        )


def test_outputs_are_consistent_across_envs() -> None:
    """spec §2.1: outputs are the same set across dev/stg/prd."""
    output_pat = re.compile(r'output\s+"([^"]+)"')
    sets: dict[str, set[str]] = {}
    for env in ENVS:
        outputs = (_env_path(env) / "outputs.tf").read_text(encoding="utf-8")
        sets[env] = set(output_pat.findall(outputs))
    assert sets["dev"] == sets["stg"] == sets["prd"], (
        "outputs differ across envs:\n"
        f"  dev only: {sets['dev'] - sets['stg'] - sets['prd']!r}\n"
        f"  stg only: {sets['stg'] - sets['dev'] - sets['prd']!r}\n"
        f"  prd only: {sets['prd'] - sets['dev'] - sets['stg']!r}"
    )


@pytest.mark.parametrize("env", ENVS)
def test_atlantis_yaml_has_project_for_env(env: str) -> None:
    """Atlantis project mapping must exist for every env directory.

    PR #15 의 머지 후 stg/prd 디렉토리는 만들어졌으나 atlantis.yaml 이
    dev 만 매핑하고 있어 stg/prd 의 `atlantis plan` 이 "0 projects" 로
    return 됐다. 본 가드는 atlantis.yaml 의 projects 블록에 모든 env 가
    포함되는지 강제 — env 디렉토리 신규 시 atlantis.yaml 동시 갱신 누락 방지.

    추가 검증 (PR #16 review): 각 project block 에 `mergeable` apply_requirement
    가 포함되어야 한다. atlantis 가 미머지 PR 의 apply 를 거부하는 핵심 gate.
    """
    yaml = (REPO_ROOT / "atlantis.yaml").read_text(encoding="utf-8")
    # Match a project entry with the env name AND its matching dir.
    project_pat = re.compile(rf"-\s+name:\s+{env}\s*\n\s+dir:\s+infra/envs/{env}\b", re.MULTILINE)
    match = project_pat.search(yaml)
    assert match, (
        f"atlantis.yaml is missing the `name: {env}` / `dir: infra/envs/{env}` project block — "
        "`atlantis plan` for that env will detect 0 projects."
    )

    # Extract the block — from the project entry header to the next "- name:" or EOF.
    block_start = match.start()
    next_match = re.search(r"\n  - name:", yaml[match.end() :])
    block_end = match.end() + next_match.start() if next_match else len(yaml)
    block = yaml[block_start:block_end]

    assert "apply_requirements" in block, (
        f"atlantis.yaml `{env}` project block has no apply_requirements"
    )
    assert "mergeable" in block, (
        f"atlantis.yaml `{env}` project block must require `mergeable` before apply"
    )


@pytest.mark.parametrize("env", ("stg", "prd"))
def test_audit_retention_5y_in_stg_prd(env: str) -> None:
    """ADR-012: 전자금융거래법 §22 — stg/prd 의 hitl_ui 호출에 audit_retention_days
    = 1825 (5년) override 가 명시되어야 한다. module default (365d) 회귀 차단."""
    main_tf = (_env_path(env) / "main.tf").read_text(encoding="utf-8")
    # hitl_ui 모듈 호출 블록 추출.
    match = re.search(r'module\s+"hitl_ui"\s*\{', main_tf)
    assert match, f"infra/envs/{env}/main.tf does not call module hitl_ui"

    # 블록 끝 (다음 module / EOF) 까지.
    rest = main_tf[match.end() :]
    end_match = re.search(r"\nmodule\s+\"", rest)
    block = rest[: end_match.start()] if end_match else rest

    assert re.search(r"audit_retention_days\s*=\s*1825\b", block), (
        f"infra/envs/{env}/main.tf hitl_ui block must set `audit_retention_days = 1825` "
        "(ADR-012 — 전자금융거래법 §22 5년 보존)"
    )
