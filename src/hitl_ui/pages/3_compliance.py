"""컴플라이언스 — 원본 STT raw 다운로드 (CloudTrail 감사 로그).

5분짜리 presigned URL 발급. S3 GetObject 이벤트가 CloudTrail Data Events 에
기록되므로 사후 감사 가능.
"""

from __future__ import annotations

import boto3
import streamlit as st
from hitl_lib.audit import emit_audit
from hitl_lib.auth import current_user, require_group
from hitl_lib.ddb_access import get_call

require_group(["compliance"])
st.title("컴플라이언스 — 원본 STT 다운로드")
st.caption("이 페이지의 모든 다운로드는 CloudTrail 에 감사 로그로 기록됩니다.")

call_id = st.text_input("callId")
if call_id:
    rec = get_call(call_id)
    if not rec:
        st.error("없음")
        st.stop()
    raw_ref = rec.get("rawSttRef", "")
    if not raw_ref:
        st.error("rawSttRef 필드가 없습니다 — 데이터 무결성 확인 필요.")
        st.stop()
    bucket = raw_ref.split("/")[2]
    key = "/".join(raw_ref.split("/")[3:])
    s3 = boto3.client("s3")
    url = s3.generate_presigned_url(
        "get_object", Params={"Bucket": bucket, "Key": key}, ExpiresIn=300
    )
    # M3: emit audit record BEFORE returning the URL — even if the user
    # never clicks, the intent-to-download is on record.
    emit_audit(
        "compliance.presigned_url",
        user=current_user(),
        call_id=call_id,
        s3_uri=raw_ref,
    )
    st.write(f"감사 사용자: {current_user()}")
    st.link_button("원본 STT 다운로드 (5분 유효)", url)
