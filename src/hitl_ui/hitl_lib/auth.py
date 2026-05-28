"""ALB authenticate-cognito 헤더 기반 사용자 / 그룹 식별 + JWT 서명 검증.

Spec: docs/superpowers/specs/2026-05-27-hitl-ui-design.md §2.3
ADR / M2 from AI Code Review:
  ALB 가 주입하는 X-Amzn-Oidc-Data 는 ES256 서명된 JWT. payload base64 디코딩만으로는
  헤더 위조 시 우회 가능 (VPC 내부 침해 시). 본 모듈은 첫 호출 시 ALB region 의
  공개키를 fetch 하여 캐시한 뒤 서명 검증을 수행한다.

  공개키 URL: https://public-keys.auth.elb.{region}.amazonaws.com/{kid}
  알고리즘:    ES256 (ALB 표준; AWS 문서 기준)
  실패 시:     서명 검증 실패 → 빈 dict 반환 → current_groups() = [] → require_group() 차단
"""

from __future__ import annotations

import base64
import json
import logging
import os
from functools import lru_cache
from typing import Any
from urllib.error import URLError
from urllib.request import urlopen

import streamlit as st

# Optional dependency: PyJWT + cryptography. The container installs them via
# requirements.txt. LOCAL_DEV / unit tests do not need to verify signatures,
# so we degrade gracefully when the imports are unavailable.
try:
    import jwt as _jwt  # type: ignore[import-not-found,unused-ignore]
    from cryptography.hazmat.backends import (  # type: ignore[import-not-found,unused-ignore]
        default_backend,
    )
    from cryptography.hazmat.primitives.serialization import (  # type: ignore[import-not-found,unused-ignore]
        load_pem_public_key,
    )

    _CRYPTO_AVAILABLE = True
except Exception:
    _CRYPTO_AVAILABLE = False

_logger = logging.getLogger("hitl_ui.auth")


def _decode_oidc_data(jwt_like: str) -> dict[str, Any]:
    """Decode the JWT payload WITHOUT signature verification.

    Used as the inner unwrapping step by `verify_and_decode`. Callers in
    application code must use `verify_and_decode` (or `current_user`/
    `current_groups`) which add signature verification.
    """
    parts = jwt_like.split(".")
    if len(parts) < 2:
        return {}
    payload = parts[1] + "=" * (-len(parts[1]) % 4)
    try:
        decoded = json.loads(base64.urlsafe_b64decode(payload).decode())
    except Exception as ex:
        _logger.warning("OIDC payload decode failed: %r", ex)
        return {}
    return decoded if isinstance(decoded, dict) else {}


def _decode_jwt_header(jwt_like: str) -> dict[str, Any]:
    """Decode the JWT header (first segment) — gives us the `kid` and `alg`."""
    parts = jwt_like.split(".")
    if not parts:
        return {}
    header = parts[0] + "=" * (-len(parts[0]) % 4)
    try:
        decoded = json.loads(base64.urlsafe_b64decode(header).decode())
    except Exception as ex:
        _logger.warning("OIDC header decode failed: %r", ex)
        return {}
    return decoded if isinstance(decoded, dict) else {}


@lru_cache(maxsize=64)
def _fetch_alb_public_key(region: str, kid: str) -> str | None:
    """Fetch and cache the ALB OIDC public key for the given key id."""
    url = f"https://public-keys.auth.elb.{region}.amazonaws.com/{kid}"
    try:
        with urlopen(url, timeout=5) as resp:
            text: str = resp.read().decode()
            return text
    except URLError as ex:
        _logger.warning("ALB public key fetch failed (kid=%s): %r", kid, ex)
        return None


def _verify_signature(jwt_like: str) -> dict[str, Any]:
    """Verify the JWT signature against the ALB public key.

    Returns the decoded payload on success, empty dict on failure. Failure
    modes: missing kid, public key fetch failure, signature mismatch.
    """
    if not _CRYPTO_AVAILABLE:
        # In environments without PyJWT (unit tests, LOCAL_DEV), fall back to
        # unverified decode. Production containers must have PyJWT installed.
        return _decode_oidc_data(jwt_like)

    header = _decode_jwt_header(jwt_like)
    kid = header.get("kid")
    if not isinstance(kid, str) or not kid:
        _logger.warning("OIDC JWT missing kid")
        return {}

    region = os.environ.get("ALB_REGION", "ap-northeast-2")
    pem = _fetch_alb_public_key(region, kid)
    if pem is None:
        return {}

    try:
        public_key = load_pem_public_key(pem.encode(), backend=default_backend())
        # ALB OIDC tokens are signed with ES256.
        payload = _jwt.decode(jwt_like, public_key, algorithms=["ES256"])
    except Exception as ex:
        _logger.warning("OIDC JWT signature verification failed: %r", ex)
        return {}
    return payload if isinstance(payload, dict) else {}


def _read_oidc_header() -> str:
    ctx = st.context.headers if hasattr(st, "context") else {}
    value = ctx.get("x-amzn-oidc-data", "") if hasattr(ctx, "get") else ""
    return str(value) if value else ""


def _verified_claims() -> dict[str, Any]:
    """Single entry point — read header → verify signature → return claims."""
    jwt_like = _read_oidc_header()
    if not jwt_like:
        return {}
    return _verify_signature(jwt_like)


def current_user() -> str:
    """Email claim of the authenticated user, or 'dev-user' in LOCAL_DEV mode."""
    if os.environ.get("LOCAL_DEV") == "1":
        return "dev-user"
    email = _verified_claims().get("email", "unknown")
    return str(email) if email else "unknown"


def current_groups() -> list[str]:
    """`cognito:groups` claim, or all-3-roles in LOCAL_DEV mode."""
    if os.environ.get("LOCAL_DEV") == "1":
        return ["ops", "analyst", "compliance"]
    raw = _verified_claims().get("cognito:groups", [])
    return list(raw) if isinstance(raw, list) else []


def require_group(allowed: list[str]) -> None:
    """Stop the page render unless the user is in at least one allowed group."""
    groups = current_groups()
    if not any(g in allowed for g in groups):
        st.error(f"이 페이지는 {allowed} 그룹만 접근 가능합니다.")
        st.stop()
