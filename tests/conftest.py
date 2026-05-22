"""Shared pytest fixtures."""
from pathlib import Path

import pytest


@pytest.fixture
def repo_root() -> Path:
    return Path(__file__).parent.parent


@pytest.fixture
def xlsx_path(repo_root: Path) -> Path:
    # xlsx 파일명은 NFD 정규화로 저장되어 있으므로 listdir로 매칭
    for f in repo_root.iterdir():
        if f.suffix == ".xlsx":
            return f
    raise FileNotFoundError("xlsx not found in repo root")
