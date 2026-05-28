"""콜센터 HITL 검수 메인 앱.

페이지는 `pages/` 디렉토리에서 Streamlit 멀티페이지 패턴으로 자동 등록된다.
ALB authenticate-cognito 가 OIDC 헤더를 주입하므로 모든 페이지는
`lib.auth.require_group()` 으로 RBAC 검증.
"""

from __future__ import annotations

import os

import streamlit as st
from hitl_lib.auth import current_user, require_group

st.set_page_config(page_title="콜센터 HITL", layout="wide")
st.title("콜센터 분류 HITL")
st.caption(f"env: `{os.environ.get('ENV', 'dev')}` — Cognito User: `{current_user()}`")
require_group(["ops", "analyst", "compliance"])
st.write("좌측 사이드바에서 페이지를 선택하세요.")
