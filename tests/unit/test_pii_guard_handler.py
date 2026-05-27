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
    # Force re-import of module-level handler (which captures env vars at import).
    sys.modules.pop("lambdas.pii_guard.handler", None)


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


@mock_aws
def test_handler_emits_pii_metric_per_type(aws_env, capsys) -> None:
    """PR9: when a PII type is masked, an EMF record must be printed for that type only."""
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
        "callId": "call_emf",
        "agentId": "A1",
        "startedAt": "2026-05-22T00:00:00Z",
        "durationSec": 30,
        "transcript": [
            {"speaker": "customer", "text": "010-1234-5678 입니다"},
        ],
    }
    s3.put_object(
        Bucket="raw-test",
        Key="2026/05/22/call_emf.json",
        Body=json.dumps(payload).encode(),
    )

    from lambdas.pii_guard.handler import handler

    handler({"rawBucket": "raw-test", "rawKey": "2026/05/22/call_emf.json"}, None)

    captured = capsys.readouterr().out
    emf_lines = [line for line in captured.splitlines() if "pii.maskApplied" in line]
    assert len(emf_lines) == 1, f"expected exactly one phone metric, got {emf_lines!r}"
    record = json.loads(emf_lines[0])
    assert record["pii_type"] == "phone"
    assert record["pii.maskApplied"] == 1.0
    # `env` dim must be present (concrete value depends on test-order isolation;
    # lib.metrics caches ENV at import, so other tests can leak ENV=stg).
    assert "env" in record
    # Namespace must be the project namespace.
    namespaces = [m["Namespace"] for m in record["_aws"]["CloudWatchMetrics"]]
    assert namespaces == ["callcenter/classification"]
