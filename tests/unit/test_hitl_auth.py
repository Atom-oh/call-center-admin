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


def _build_oidc_jwt(payload: dict, header: dict | None = None) -> str:
    """Build a fake unsigned JWT — header.payload.signature.

    `header` overrides the default `{"alg": "none"}` so signer/kid-dependent
    paths (ADR-011 signer hardening) can be exercised.
    """
    header = header if header is not None else {"alg": "none"}
    header_b64 = base64.urlsafe_b64encode(json.dumps(header).encode()).decode().rstrip("=")
    payload_b64 = base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip("=")
    return f"{header_b64}.{payload_b64}.sig"


_ALB_ARN = "arn:aws:elasticloadbalancing:ap-northeast-2:111122223333:loadbalancer/app/callcenter-dev/abc123"


def test_decode_oidc_jwt_payload(fake_streamlit) -> None:
    """The JWT middle segment must decode to the expected dict."""
    from hitl_lib.auth import _decode_oidc_data

    jwt = _build_oidc_jwt({"email": "alice@example.com", "cognito:groups": ["ops"]})
    decoded = _decode_oidc_data(jwt)
    assert decoded["email"] == "alice@example.com"
    assert decoded["cognito:groups"] == ["ops"]


def test_current_user_returns_email_from_oidc(fake_streamlit, monkeypatch) -> None:
    """ALB injects X-Amzn-Oidc-Data — current_user reads the email claim.

    The signature verification path is exercised in production with PyJWT
    installed; here we stub `_verify_signature` so we can validate the
    claim-extraction logic independent of the crypto layer.
    """
    monkeypatch.delenv("LOCAL_DEV", raising=False)
    jwt = _build_oidc_jwt({"email": "bob@example.com", "cognito:groups": ["analyst"]})
    fake_streamlit.context.headers = {"x-amzn-oidc-data": jwt}

    # Stub verify so this test focuses on claim extraction, not crypto.
    import hitl_lib.auth as auth_mod

    monkeypatch.setattr(
        auth_mod,
        "_verify_signature",
        lambda j: {"email": "bob@example.com", "cognito:groups": ["analyst"]},
    )

    from hitl_lib.auth import current_user

    assert current_user() == "bob@example.com"


def test_current_groups_returns_cognito_groups(fake_streamlit, monkeypatch) -> None:
    """current_groups reads the cognito:groups claim from the same header."""
    monkeypatch.delenv("LOCAL_DEV", raising=False)
    jwt = _build_oidc_jwt({"email": "c@example.com", "cognito:groups": ["compliance", "ops"]})
    fake_streamlit.context.headers = {"x-amzn-oidc-data": jwt}

    import hitl_lib.auth as auth_mod

    monkeypatch.setattr(
        auth_mod,
        "_verify_signature",
        lambda j: {"email": "c@example.com", "cognito:groups": ["compliance", "ops"]},
    )

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


def test_fail_closed_when_crypto_unavailable_and_not_local_dev(fake_streamlit, monkeypatch) -> None:
    """M1 from 2nd AI review: when PyJWT/cryptography are unavailable AND
    LOCAL_DEV is not set, _verify_signature MUST return an empty dict so the
    auth layer refuses to issue any claims (fail-closed, never fail-open)."""
    monkeypatch.delenv("LOCAL_DEV", raising=False)
    jwt = _build_oidc_jwt({"email": "attacker@example.com", "cognito:groups": ["ops"]})
    fake_streamlit.context.headers = {"x-amzn-oidc-data": jwt}

    import hitl_lib.auth as auth_mod

    # Force the crypto-unavailable branch.
    monkeypatch.setattr(auth_mod, "_CRYPTO_AVAILABLE", False)

    from hitl_lib.auth import current_groups, current_user

    # Even with a valid-looking header, no claims must be issued.
    assert current_user() == "unknown"
    assert current_groups() == []


# ── ADR-011 hardening: signer == ALB_ARN verification ──────────────────────
# The ALB public-key endpoint (public-keys.auth.elb.<region>.amazonaws.com/<kid>)
# serves keys for EVERY ALB in the region, so a token minted by a *different*
# ALB would still pass the raw ES256 signature check. AWS documents verifying
# the JWT header's `signer` field equals your own ALB ARN. The gate runs in the
# crypto-available branch, after the kid check, BEFORE fetching the public key.


def test_verify_signature_rejects_foreign_alb_signer(fake_streamlit, monkeypatch) -> None:
    """ALB_ARN set + header.signer is a DIFFERENT ALB → refuse claims, and never
    even fetch the public key (reject early)."""
    monkeypatch.delenv("LOCAL_DEV", raising=False)
    monkeypatch.setenv("ALB_ARN", _ALB_ARN)
    jwt = _build_oidc_jwt(
        {"email": "attacker@example.com", "cognito:groups": ["ops"]},
        header={
            "alg": "ES256",
            "kid": "k1",
            "signer": "arn:aws:elasticloadbalancing:ap-northeast-2:999999999999:loadbalancer/app/evil/deadbeef",
        },
    )
    fake_streamlit.context.headers = {"x-amzn-oidc-data": jwt}

    import hitl_lib.auth as auth_mod

    monkeypatch.setattr(auth_mod, "_CRYPTO_AVAILABLE", True)
    fetch_spy = MagicMock(return_value=None)
    monkeypatch.setattr(auth_mod, "_fetch_alb_public_key", fetch_spy)

    assert auth_mod._verify_signature(jwt) == {}
    fetch_spy.assert_not_called()  # rejected before any key fetch


def test_verify_signature_accepts_matching_signer(fake_streamlit, monkeypatch) -> None:
    """ALB_ARN set + header.signer == ALB_ARN → gate passes (proceeds to key
    fetch). We stub the fetch to None so the test stays crypto-free; the point
    is that the matching signer is NOT rejected at the gate."""
    monkeypatch.delenv("LOCAL_DEV", raising=False)
    monkeypatch.setenv("ALB_ARN", _ALB_ARN)
    jwt = _build_oidc_jwt(
        {"email": "ok@example.com", "cognito:groups": ["ops"]},
        header={"alg": "ES256", "kid": "k1", "signer": _ALB_ARN},
    )
    fake_streamlit.context.headers = {"x-amzn-oidc-data": jwt}

    import hitl_lib.auth as auth_mod

    monkeypatch.setattr(auth_mod, "_CRYPTO_AVAILABLE", True)
    fetch_spy = MagicMock(return_value=None)
    monkeypatch.setattr(auth_mod, "_fetch_alb_public_key", fetch_spy)

    auth_mod._verify_signature(jwt)
    fetch_spy.assert_called_once()  # gate passed → proceeded to key fetch


def test_verify_signature_skips_signer_gate_when_alb_arn_unset(fake_streamlit, monkeypatch) -> None:
    """No ALB_ARN configured (LOCAL_DEV/desktop) → signer gate is skipped; flow
    proceeds to key fetch regardless of the signer header."""
    monkeypatch.delenv("LOCAL_DEV", raising=False)
    monkeypatch.delenv("ALB_ARN", raising=False)
    jwt = _build_oidc_jwt(
        {"email": "ok@example.com", "cognito:groups": ["ops"]},
        header={"alg": "ES256", "kid": "k1", "signer": "anything"},
    )
    fake_streamlit.context.headers = {"x-amzn-oidc-data": jwt}

    import hitl_lib.auth as auth_mod

    monkeypatch.setattr(auth_mod, "_CRYPTO_AVAILABLE", True)
    fetch_spy = MagicMock(return_value=None)
    monkeypatch.setattr(auth_mod, "_fetch_alb_public_key", fetch_spy)

    auth_mod._verify_signature(jwt)
    fetch_spy.assert_called_once()  # no gate → proceeded
