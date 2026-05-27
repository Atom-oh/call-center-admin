"""검토 대기열 — status=hitl-pending 페이지네이션 + 단건 교정.

ADR-004: 분류 selectbox 의 label 은 `{name} ({code})` 형식으로 xlsx code 그대로 표시.
ADR-003: 교정 시 `update_correction` 이 reason 컬럼을 만지지 않음 (lib.ddb_access).
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import boto3
import streamlit as st
from hitl_lib.auth import current_user, require_group
from hitl_lib.ddb_access import list_review_queue, update_correction, update_skip

require_group(["ops"])
st.title("검토 대기열")

if "queue_page_key" not in st.session_state:
    st.session_state.queue_page_key = None

items, next_key = list_review_queue(limit=20, last_key=st.session_state.queue_page_key)
if not items:
    st.info("대기열이 비었습니다.")
    st.stop()

call_ids = [it["callId"] for it in items]
selected = st.selectbox("검토할 통화 선택", call_ids)
record: dict[str, Any] = next(it for it in items if it["callId"] == selected)

st.subheader(selected)
col_a, col_b = st.columns([1, 1])
with col_a:
    st.markdown("**모델 분류 (대/중/소)**")
    st.write(f"대: `{record['category_대code']}` ({record['category_대name']})")
    st.write(f"중: `{record['category_중code']}` ({record['category_중name']})")
    st.write(f"소: `{record['category_소code']}` ({record['category_소name']})")
    st.write(f"confidence: `{record['confidence']}`")
    st.write(f"reason: {record['reason']}")
with col_b:
    st.markdown("**마스킹된 transcript**")
    masked_ref = record.get("piiMaskedTextRef", "")
    if masked_ref:
        s3 = boto3.client("s3")
        bucket = masked_ref.split("/")[2]
        key = "/".join(masked_ref.split("/")[3:])
        text = s3.get_object(Bucket=bucket, Key=key)["Body"].read().decode()
        st.text(text)

# 교정 UI — 분류 트리 cascade.
_TREE_PATH = Path("/app/prompts/v1.0/taxonomy_tree.json")
if _TREE_PATH.exists():
    TREE = json.loads(_TREE_PATH.read_text(encoding="utf-8"))
    # taxonomy_tree.json 은 nested 구조. flatten 으로 cascade 처리.
    flat: list[dict[str, Any]] = []

    def _walk(node: dict[str, Any], parent_code: str | None) -> None:
        flat.append({**node, "parent_code": parent_code})
        for child in node.get("children", []):
            _walk(child, node.get("code"))

    for top in TREE.get("nodes", TREE) if isinstance(TREE, dict) else TREE:
        _walk(top, None)

    top_level = [n for n in flat if n.get("level") == 1]
else:
    top_level = []

st.markdown("---")
st.subheader("교정")
if top_level:
    sel_대 = st.selectbox("대분류", top_level, format_func=lambda n: f"{n['name']} ({n['code']})")
    mids = [n for n in flat if n.get("level") == 2 and n.get("parent_code") == sel_대["code"]]
    sel_중 = (
        st.selectbox("중분류", mids, format_func=lambda n: f"{n['name']} ({n['code']})")
        if mids
        else None
    )
    leaves = (
        [n for n in flat if n.get("level") == 3 and n.get("parent_code") == sel_중["code"]]
        if sel_중
        else []
    )
    sel_소 = (
        st.selectbox("소분류", leaves, format_func=lambda n: f"{n['name']} ({n['code']})")
        if leaves
        else None
    )
else:
    sel_대 = sel_중 = sel_소 = None
    st.warning("분류 트리 파일을 찾을 수 없습니다 (/app/prompts/v1.0/taxonomy_tree.json).")

cc1, cc2, cc3 = st.columns(3)
with cc1:
    if st.button("이 분류가 맞다", use_container_width=True):
        update_correction(
            selected,
            {
                "대code": record["category_대code"],
                "중code": record["category_중code"],
                "소code": record["category_소code"],
            },
            current_user(),
        )
        st.success("확정")
        st.rerun()
with cc2:
    can_save = sel_대 is not None and sel_중 is not None and sel_소 is not None
    if st.button("교정 저장", use_container_width=True, type="primary", disabled=not can_save):
        assert sel_대 and sel_중 and sel_소  # type narrowing for mypy
        update_correction(
            selected,
            {"대code": sel_대["code"], "중code": sel_중["code"], "소code": sel_소["code"]},
            current_user(),
        )
        st.success("교정 저장")
        st.rerun()
with cc3:
    if st.button("스킵 (불분명)", use_container_width=True):
        update_skip(selected, current_user())
        st.info("스킵")
        st.rerun()
