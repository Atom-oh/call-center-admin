"""ALB authenticate-cognito 헤더 기반 사용자 / 그룹 식별.

Spec: docs/superpowers/specs/2026-05-27-hitl-ui-design.md §2.3
"""

from __future__ import annotations

import base64
import json
import os
from typing import Any

import streamlit as st


def _decode_oidc_data(jwt_like: str) -> dict[str, Any]:
    """Decode the middle (payload) segment of the ALB-injected OIDC JWT."""
    parts = jwt_like.split(".")
    if len(parts) < 2:
        return {}
    payload = parts[1] + "=" * (-len(parts[1]) % 4)
    try:
        decoded = json.loads(base64.urlsafe_b64decode(payload).decode())
    except Exception:
        return {}
    return decoded if isinstance(decoded, dict) else {}


def _read_oidc_header() -> str:
    ctx = st.context.headers if hasattr(st, "context") else {}
    value = ctx.get("x-amzn-oidc-data", "") if hasattr(ctx, "get") else ""
    return str(value) if value else ""


def current_user() -> str:
    """Email claim of the authenticated user, or 'dev-user' in LOCAL_DEV mode."""
    if os.environ.get("LOCAL_DEV") == "1":
        return "dev-user"
    email = _decode_oidc_data(_read_oidc_header()).get("email", "unknown")
    return str(email) if email else "unknown"


def current_groups() -> list[str]:
    """`cognito:groups` claim, or all-3-roles in LOCAL_DEV mode."""
    if os.environ.get("LOCAL_DEV") == "1":
        return ["ops", "analyst", "compliance"]
    raw = _decode_oidc_data(_read_oidc_header()).get("cognito:groups", [])
    return list(raw) if isinstance(raw, list) else []


def require_group(allowed: list[str]) -> None:
    """Stop the page render unless the user is in at least one allowed group."""
    groups = current_groups()
    if not any(g in allowed for g in groups):
        st.error(f"이 페이지는 {allowed} 그룹만 접근 가능합니다.")
        st.stop()
