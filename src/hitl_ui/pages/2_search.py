"""검색 — 상담원ID 또는 대분류 코드로 필터."""

from __future__ import annotations

import streamlit as st
from hitl_lib.auth import require_group
from hitl_lib.ddb_access import search_by_agent, search_by_category

require_group(["ops", "analyst"])
st.title("검색")

mode = st.radio("검색 기준", ["상담원ID", "대분류"])
if mode == "상담원ID":
    agent = st.text_input("상담원ID")
    if agent:
        st.dataframe(search_by_agent(agent))
else:
    code = st.text_input("대분류 코드 (예: CS_CENTER_CONSULT_TYPE_PAY_NONEY)")
    if code:
        st.dataframe(search_by_category(code))
