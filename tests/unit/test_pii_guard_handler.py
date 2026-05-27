"""PII Guard Lambda handler test with moto S3 mock."""

import json
import sys

import boto3
import pytest
from moto import mock_aws


@pytest.fixture
def aws_env(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", "ap-northeast-2")
    monkeypatch.setenv("MASKED_BUCKET", "masked-test")
    # Module-level _s3 / _MASKED_BUCKET cache: force re-import per test.
    sys.modules.pop("lambdas.pii_guard.handler", None)


@pytest.fixture
def raw_bucket_with_phone_payload():
    """Helper: stand up raw + masked buckets, write a transcript carrying a phone PII."""

    def _setup(call_id: str) -> str:
        s3 = boto3.client("s3", region_name="ap-northeast-2")
        s3.create_bucket(
            Bucket="raw-test",
            CreateBucketConfiguration={"LocationConstraint": "ap-northeast-2"},
        )
        s3.create_bucket(
            Bucket="masked-test",
            CreateBucketConfiguration={"LocationConstraint": "ap-northeast-2"},
        )
        payload = {
            "callId": call_id,
            "agentId": "A1",
            "startedAt": "2026-05-22T00:00:00Z",
            "durationSec": 60,
            "transcript": [
                {"speaker": "customer", "text": "010-1234-5678 입니다"},
            ],
        }
        key = f"2026/05/22/{call_id}.json"
        s3.put_object(Bucket="raw-test", Key=key, Body=json.dumps(payload).encode())
        return key

    return _setup


@mock_aws
def test_handler_masks_and_uploads(aws_env, monkeypatch) -> None:
    s3 = boto3.client("s3", region_name="ap-northeast-2")
    s3.create_bucket(
        Bucket="raw-test",
        CreateBucketConfiguration={"LocationConstraint": "ap-northeast-2"},
    )
    s3.create_bucket(
        Bucket="masked-test",
        CreateBucketConfiguration={"LocationConstraint": "ap-northeast-2"},
    )
    payload = {
        "callId": "call_001",
        "agentId": "A1",
        "startedAt": "2026-05-22T00:00:00Z",
        "durationSec": 60,
        "transcript": [
            {"speaker": "customer", "text": "010-1234-5678 입니다"},
        ],
    }
    s3.put_object(
        Bucket="raw-test",
        Key="2026/05/22/call_001.json",
        Body=json.dumps(payload).encode(),
    )

    # Import after monkeypatched env and moto active
    from lambdas.pii_guard.handler import handler

    event = {"rawBucket": "raw-test", "rawKey": "2026/05/22/call_001.json"}
    result = handler(event, None)

    assert result["maskedBucket"] == "masked-test"
    assert "call_001_masked.txt" in result["maskedKey"]
    assert result["maskStats"]["phone"] == 1
    assert result["callId"] == "call_001"

    obj = s3.get_object(Bucket="masked-test", Key=result["maskedKey"])
    masked = obj["Body"].read().decode()
    assert "[MASKED_PHONE]" in masked
    assert "010-1234-5678" not in masked


# ──────────────────────────────────────────────────────────────────────────
# PR9 — Observability EMF emit (spec §6.1)
# ──────────────────────────────────────────────────────────────────────────


@mock_aws
def test_handler_emits_pii_metric_per_type(aws_env, raw_bucket_with_phone_payload, capsys) -> None:
    """spec §2.1 / Decision-G2: per-PII-type EMF, zero-count types are skipped."""
    key = raw_bucket_with_phone_payload("call_emf_001")

    from lambdas.pii_guard.handler import handler

    handler({"rawBucket": "raw-test", "rawKey": key}, None)

    captured = capsys.readouterr().out
    emf_lines = [line for line in captured.splitlines() if "pii.maskApplied" in line]
    assert len(emf_lines) == 1, (
        f"expected exactly one phone metric (zero-count types skipped), got {emf_lines!r}"
    )
    record = json.loads(emf_lines[0])
    assert record["pii_type"] == "phone"
    assert record["pii.maskApplied"] == 1.0
    # Namespace must be the project namespace (single CloudWatchMetrics record).
    namespaces = [m["Namespace"] for m in record["_aws"]["CloudWatchMetrics"]]
    assert namespaces == ["callcenter/classification"]


@mock_aws
def test_pii_metric_does_not_leak_text(aws_env, raw_bucket_with_phone_payload, capsys) -> None:
    """ADR-003 Layer-2 guard: EMF record must (a) be emitted AND (b) not contain text.

    (a) ensures the test isn't trivially passing when emit is missing entirely.
    (b) ensures dim/value carry counts only, not the masked or raw transcript.
    """
    key = raw_bucket_with_phone_payload("call_emf_002")

    from lambdas.pii_guard.handler import handler

    handler({"rawBucket": "raw-test", "rawKey": key}, None)

    captured_text = capsys.readouterr().out

    # (a) Must have at least one EMF record for pii.maskApplied — otherwise the
    # leak guard is vacuously true.
    assert "pii.maskApplied" in captured_text, "no EMF record emitted — guard vacuous"

    # (b) That record must not carry PII text in any form.
    assert "010-1234-5678" not in captured_text, "raw phone leaked into EMF stream"
    assert "[MASKED_PHONE]" not in captured_text, "masked sentinel leaked into EMF stream"
    assert "입니다" not in captured_text, "transcript text leaked into EMF stream"
