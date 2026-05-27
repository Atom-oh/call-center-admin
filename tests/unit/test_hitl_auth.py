"""HITL UI auth helpers — 단위 테스트 (spec §6.2).

OIDC JWT 디코딩 / RBAC 그룹 검사 / LOCAL_DEV escape.

streamlit 모듈은 실제 import 가 무거우므로 sys.modules 에 MagicMock 으로 치환.
"""

from __future__ import annotations

import base64
import json
import sys
from pathlib import Path
from unittest.mock import MagicMock

import pytest

# Make src/hitl_ui visible.
_HITL_ROOT = Path(__file__).parent.parent.parent / "src" / "hitl_ui"
if str(_HITL_ROOT) not in sys.path:
    sys.path.insert(0, str(_HITL_ROOT))


@pytest.fixture
def fake_streamlit(monkeypatch):
    """Replace `streamlit` import with a minimal mock; tests own the headers."""
    st_mock = MagicMock()
    st_mock.context = MagicMock()
    st_mock.context.headers = {}
    monkeypatch.setitem(sys.modules, "streamlit", st_mock)
    sys.modules.pop("hitl_lib.auth", None)
    return st_mock


def _build_oidc_jwt(payload: dict) -> str:
    """Build a fake unsigned JWT — header.payload.signature."""
    header_b64 = base64.urlsafe_b64encode(json.dumps({"alg": "none"}).encode()).decode().rstrip("=")
    payload_b64 = base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip("=")
    return f"{header_b64}.{payload_b64}.sig"


def test_decode_oidc_jwt_payload(fake_streamlit) -> None:
    """The JWT middle segment must decode to the expected dict."""
    from hitl_lib.auth import _decode_oidc_data

    jwt = _build_oidc_jwt({"email": "alice@example.com", "cognito:groups": ["ops"]})
    decoded = _decode_oidc_data(jwt)
    assert decoded["email"] == "alice@example.com"
    assert decoded["cognito:groups"] == ["ops"]


def test_current_user_returns_email_from_oidc(fake_streamlit, monkeypatch) -> None:
    """ALB injects X-Amzn-Oidc-Data — current_user reads the email claim."""
    monkeypatch.delenv("LOCAL_DEV", raising=False)
    jwt = _build_oidc_jwt({"email": "bob@example.com", "cognito:groups": ["analyst"]})
    fake_streamlit.context.headers = {"x-amzn-oidc-data": jwt}

    from hitl_lib.auth import current_user

    assert current_user() == "bob@example.com"


def test_current_groups_returns_cognito_groups(fake_streamlit, monkeypatch) -> None:
    """current_groups reads the cognito:groups claim from the same header."""
    monkeypatch.delenv("LOCAL_DEV", raising=False)
    jwt = _build_oidc_jwt({"email": "c@example.com", "cognito:groups": ["compliance", "ops"]})
    fake_streamlit.context.headers = {"x-amzn-oidc-data": jwt}

    from hitl_lib.auth import current_groups

    assert current_groups() == ["compliance", "ops"]


def test_local_dev_escape_grants_all_groups(fake_streamlit, monkeypatch) -> None:
    """LOCAL_DEV=1 returns dev-user + all 3 groups (pytest / desktop dev)."""
    monkeypatch.setenv("LOCAL_DEV", "1")

    from hitl_lib.auth import current_groups, current_user

    assert current_user() == "dev-user"
    groups = current_groups()
    for required in ("ops", "analyst", "compliance"):
        assert required in groups, f"LOCAL_DEV escape missing group: {required}"


def test_local_dev_escape_disabled_when_env_unset(fake_streamlit, monkeypatch) -> None:
    """Without LOCAL_DEV, missing header → unknown user, empty groups (must NOT
    silently grant access — security invariant)."""
    monkeypatch.delenv("LOCAL_DEV", raising=False)
    fake_streamlit.context.headers = {}

    from hitl_lib.auth import current_groups, current_user

    assert current_user() == "unknown"
    assert current_groups() == []
