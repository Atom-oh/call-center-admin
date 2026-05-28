"""HITL audit logging — Cognito user → action → callId trail.

Spec: M3 from AI Code Review on PR #14
Rationale:
  S3 presigned URL 발급 후 사용자가 다운로드하면 CloudTrail S3 GetObject 이벤트의
  principal 은 ECS task role 만 기록 — 어느 Cognito 사용자가 클릭했는지 추적 불가.
  본 모듈은 (a) DDB UpdateItem (correction/skip), (b) S3 presigned URL 발급 직전에
  별도 CloudWatch log group `/hitl-ui/audit/...` 으로 구조화 JSON record 를 emit.
  PR9 observability dashboard 에 metric/알람 추가 가능.

ADR-006: 추가 KMS 권한 0 (audit log group 는 CW Logs 자체 암호화).
"""

from __future__ import annotations

import json
import logging
import os
import time
import uuid

import boto3

_logger = logging.getLogger("hitl_ui.audit")

# AUDIT_LOG_GROUP 가 비어 있으면 stdout 로 fall back — LOCAL_DEV / 단위 테스트 경로.
_AUDIT_GROUP = os.environ.get("AUDIT_LOG_GROUP", "")
_logs_client = boto3.client("logs") if _AUDIT_GROUP else None
_stream_name = f"audit-{os.environ.get('ENV', 'local')}-{uuid.uuid4().hex[:8]}"
_stream_initialized = False


def _ensure_stream() -> bool:
    """Create the per-task log stream once. Returns True on success."""
    global _stream_initialized
    if _stream_initialized or not _logs_client or not _AUDIT_GROUP:
        return _stream_initialized
    try:
        _logs_client.create_log_stream(logGroupName=_AUDIT_GROUP, logStreamName=_stream_name)
        _stream_initialized = True
    except Exception as ex:
        # Stream may already exist from a previous container start — that is OK.
        if "ResourceAlreadyExistsException" in repr(ex):
            _stream_initialized = True
        else:
            _logger.warning("audit log stream init failed: %r", ex)
            return False
    return _stream_initialized


def emit_audit(action: str, user: str, call_id: str, **extras: object) -> None:
    """Write one audit record. Never raises — audit must not break the UI flow.

    Schema:
        { ts, action, user, callId, ...extras }
    """
    record = {
        "ts": int(time.time() * 1000),
        "action": action,
        "user": user,
        "callId": call_id,
        **{k: v for k, v in extras.items() if v is not None},
    }
    payload = json.dumps(record, ensure_ascii=False)

    # LOCAL_DEV / unit tests: print to stdout instead of CloudWatch.
    if not _logs_client or not _AUDIT_GROUP or not _ensure_stream():
        print(f"AUDIT {payload}", flush=True)
        return

    try:
        _logs_client.put_log_events(
            logGroupName=_AUDIT_GROUP,
            logStreamName=_stream_name,
            logEvents=[{"timestamp": record["ts"], "message": payload}],
        )
    except Exception as ex:
        # Log to stderr as fallback; never raise.
        _logger.warning("audit emit failed for %s: %r", action, ex)
        print(f"AUDIT_FALLBACK {payload}", flush=True)
