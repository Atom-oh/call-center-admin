"""Classify Lambda handler test with mocked Bedrock + mocked S3."""

import json
import os
import sys
from unittest.mock import MagicMock, patch

import boto3
import pytest
from moto import mock_aws


@pytest.fixture
def aws_env(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", "ap-northeast-2")
    monkeypatch.setenv("AWS_REGION", "ap-northeast-2")
    monkeypatch.setenv("MODEL_ID", "global.anthropic.claude-opus-4-7")
    monkeypatch.setenv("PROMPT_DIR", "src/prompts/v1.0")
    # Re-import: module-level _ADAPTER caches the patched bedrock client.
    sys.modules.pop("lambdas.classify.handler", None)


def _fake_bedrock_with_code(daecode: str = "CS_CENTER_CONSULT_TYPE_PAY_NONEY"):
    """Build a MagicMock Bedrock client returning a valid v1.0 classification."""
    body = json.dumps(
        {
            "대": {"code": daecode, "name": "페이머니"},
            "중": {
                "code": "CS_CENTER_CONSULT_TYPE_PAY_NONEY_CHARGE_WITHDRAWAL",
                "name": "충전/출금",
            },
            "소": {
                "code": "CS_CENTER_CONSULT_TYPE_PAY_NONEY_CHARGE_WITHDRAWAL_CHARGE_DELAY",
                "name": "충전 지연/오류",
            },
            "confidence": 0.77,
            "reason": "고객이 충전 오류를 호소함",
            "alternativesConsidered": [],
        }
    )
    fake = MagicMock()
    fake.converse.return_value = {"output": {"message": {"content": [{"text": body}]}}}
    return fake


@mock_aws
def test_classify_returns_structured_result(aws_env) -> None:
    s3 = boto3.client("s3", region_name="ap-northeast-2")
    s3.create_bucket(
        Bucket="masked-test",
        CreateBucketConfiguration={"LocationConstraint": "ap-northeast-2"},
    )
    s3.put_object(Bucket="masked-test", Key="x_masked.txt", Body=b"agent: hi")

    # Use a known valid code from v1.0 taxonomy (already generated and committed)
    body = json.dumps(
        {
            "대": {"code": "CS_CENTER_CONSULT_TYPE_PAY_NONEY", "name": "페이머니"},
            "중": {
                "code": "CS_CENTER_CONSULT_TYPE_PAY_NONEY_CHARGE_WITHDRAWAL",
                "name": "충전/출금",
            },
            "소": {
                "code": "CS_CENTER_CONSULT_TYPE_PAY_NONEY_CHARGE_WITHDRAWAL_CHARGE_DELAY",
                "name": "충전 지연/오류",
            },
            "confidence": 0.91,
            "reason": "고객이 충전 오류를 호소함",
            "alternativesConsidered": [],
        }
    )
    fake_bedrock_resp = {"output": {"message": {"content": [{"text": body}]}}}
    fake_client = MagicMock()
    fake_client.converse.return_value = fake_bedrock_resp

    with patch("lib.bedrock_client.boto3.client", return_value=fake_client):
        # Import after the patch + moto active + env set
        from lambdas.classify.handler import handler

        result = handler(
            {
                "callId": "call_1",
                "maskedBucket": "masked-test",
                "maskedKey": "x_masked.txt",
            },
            None,
        )
        assert result["classification"]["confidence"] == 0.91
        assert result["modelId"] == os.environ["MODEL_ID"]
        assert result["promptVersion"] == "v1.0"


# ──────────────────────────────────────────────────────────────────────────
# PR9 — Observability EMF emit (spec §6.1)
# ──────────────────────────────────────────────────────────────────────────


@mock_aws
def test_classify_emits_invoked_and_confidence(aws_env, capsys) -> None:
    """spec §2.1: classify must emit both invoked count and confidence as EMF."""
    s3 = boto3.client("s3", region_name="ap-northeast-2")
    s3.create_bucket(
        Bucket="masked-test",
        CreateBucketConfiguration={"LocationConstraint": "ap-northeast-2"},
    )
    s3.put_object(Bucket="masked-test", Key="x_masked.txt", Body=b"agent: hi")

    with patch("lib.bedrock_client.boto3.client", return_value=_fake_bedrock_with_code()):
        from lambdas.classify.handler import handler

        handler(
            {
                "callId": "call_emf",
                "maskedBucket": "masked-test",
                "maskedKey": "x_masked.txt",
            },
            None,
        )

    captured = capsys.readouterr().out
    metric_names: list[str] = []
    for line in captured.splitlines():
        if not line.startswith("{"):
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        for m in record.get("_aws", {}).get("CloudWatchMetrics", []):
            for metric in m["Metrics"]:
                metric_names.append(metric["Name"])
    assert "classify.invoked" in metric_names, "missing classify.invoked metric"
    assert "classify.confidence" in metric_names, "missing classify.confidence metric"


@mock_aws
def test_classify_metric_uses_xlsx_code_verbatim(aws_env, capsys) -> None:
    """ADR-004 guard: xlsx code (e.g. NONEY) must appear verbatim in metric dim.

    A future linter MUST NOT 'fix' the typo to MONEY — downstream RPA depends on
    the literal string.
    """
    s3 = boto3.client("s3", region_name="ap-northeast-2")
    s3.create_bucket(
        Bucket="masked-test",
        CreateBucketConfiguration={"LocationConstraint": "ap-northeast-2"},
    )
    s3.put_object(Bucket="masked-test", Key="x_masked.txt", Body=b"agent: hi")

    daecode = "CS_CENTER_CONSULT_TYPE_PAY_NONEY"  # NONEY typo preserved
    with patch("lib.bedrock_client.boto3.client", return_value=_fake_bedrock_with_code(daecode)):
        from lambdas.classify.handler import handler

        handler(
            {
                "callId": "call_emf",
                "maskedBucket": "masked-test",
                "maskedKey": "x_masked.txt",
            },
            None,
        )

    captured = capsys.readouterr().out
    # NONEY must appear as the dim value, MONEY (the 'corrected' form) must not.
    assert "NONEY" in captured, "xlsx code identifier NONEY missing from EMF"
    # Strict: MONEY token (with word boundaries) should not appear because nothing
    # else in the test data uses that token.
    assert "MONEY" not in captured.replace("NONEY", ""), (
        "MONEY appeared — code was 'corrected', violating ADR-004"
    )
