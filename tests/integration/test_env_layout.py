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
# hitl_ui module 은 PR8 머지 후 별도 follow-up 으로 dev/stg/prd 에 추가.
# 본 PR10 의 REQUIRED_MODULES 는 PR9 머지된 main 기준으로 6 module.
REQUIRED_MODULES = (
    "shared",
    "storage",
    "analytics",
    "classify_pipeline",
    "observability",
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
