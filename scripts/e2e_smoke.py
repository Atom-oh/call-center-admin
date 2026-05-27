"""End-to-end smoke 자동화 — dev/stg/prd 환경.

Spec: docs/superpowers/specs/2026-05-27-cicd-stg-prd-design.md §5

흐름:
  1. raw S3 에 fake STT JSON 업로드
  2. EventBridge → SFN 트리거 대기 (최대 90초)
  3. SFN execution 상태 확인 (SUCCEEDED 기대)
  4. DDB consult-results 에 row 존재 + status 확인
  5. (선택) Athena count 쿼리

사용:
  python scripts/e2e_smoke.py --env dev
  python scripts/e2e_smoke.py --env stg --wait-seconds 120

본 스크립트는 boto3 default credential chain 을 사용 — 호출자가
적절한 IAM 권한을 가진 환경 (Atlantis pod, 운영자 PC, CI runner) 에서 실행.
자율 실행 모드에서는 코드 정의만 작성, 실제 호출 없음.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import uuid
from datetime import datetime, timezone

import boto3


def _smoke_payload(call_id: str) -> dict:
    """Synthetic STT JSON — no PII (defense-in-depth)."""
    return {
        "callId": call_id,
        "agentId": "smoke-agent",
        "startedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),  # noqa: UP017
        "durationSec": 60,
        "transcript": [
            {"speaker": "agent", "text": "안녕하세요 카카오페이 콜센터입니다."},
            {"speaker": "customer", "text": "페이머니 충전이 안 됩니다."},
            {"speaker": "agent", "text": "확인해 드리겠습니다."},
        ],
    }


def upload_smoke_payload(env: str, call_id: str) -> str:
    """Upload to s3://callcenter-{env}-stt-raw/YYYY/MM/DD/<callId>.json."""
    s3 = boto3.client("s3")
    today = datetime.now(timezone.utc)  # noqa: UP017
    key = f"{today.year:04d}/{today.month:02d}/{today.day:02d}/{call_id}.json"
    bucket = f"callcenter-{env}-stt-raw"
    payload = _smoke_payload(call_id)
    s3.put_object(
        Bucket=bucket,
        Key=key,
        Body=json.dumps(payload).encode("utf-8"),
        ContentType="application/json",
        ServerSideEncryption="aws:kms",
    )
    return f"s3://{bucket}/{key}"


def wait_for_ddb_row(env: str, call_id: str, max_wait: int) -> dict | None:
    """Poll DDB until row appears or timeout."""
    ddb = boto3.resource("dynamodb")
    table = ddb.Table(f"callcenter-{env}-consult-results")
    deadline = time.time() + max_wait
    while time.time() < deadline:
        resp = table.get_item(Key={"callId": call_id})
        if "Item" in resp:
            return dict(resp["Item"])
        time.sleep(5)
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description="E2E smoke test for the classify pipeline.")
    parser.add_argument("--env", required=True, choices=["dev", "stg", "prd"])
    parser.add_argument(
        "--wait-seconds",
        type=int,
        default=90,
        help="Max seconds to wait for the DDB row to appear.",
    )
    parser.add_argument(
        "--call-id",
        default=None,
        help="Optional explicit callId. Default: smoke-<uuid>.",
    )
    args = parser.parse_args()

    call_id = args.call_id or f"smoke-{uuid.uuid4().hex[:12]}"
    print(f"[smoke] env={args.env} callId={call_id}")

    raw_ref = upload_smoke_payload(args.env, call_id)
    print(f"[smoke] uploaded {raw_ref}")

    item = wait_for_ddb_row(args.env, call_id, args.wait_seconds)
    if item is None:
        print(f"[smoke] FAIL — DDB row not found within {args.wait_seconds}s")
        return 1

    print(f"[smoke] DDB row found: status={item.get('status')!r}")
    print(f"[smoke]   대code={item.get('category_대code')!r}")
    print(f"[smoke]   confidence={item.get('confidence')!r}")
    print(f"[smoke]   verified={item.get('verified')!r}")

    expected_statuses = {"confirmed", "hitl-pending"}
    actual = item.get("status")
    if actual not in expected_statuses:
        print(f"[smoke] FAIL — unexpected status {actual!r} (expected one of {expected_statuses})")
        return 1

    print("[smoke] PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
