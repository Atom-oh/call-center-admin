"""Classify Lambda handler test with mocked Bedrock + mocked S3."""

import json
import os
from unittest.mock import MagicMock, patch

import boto3
import pytest
from moto import mock_aws


@pytest.fixture
def aws_env(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", "ap-northeast-2")
    monkeypatch.setenv("AWS_REGION", "ap-northeast-2")
    monkeypatch.setenv("MODEL_ID", "anthropic.claude-opus-4-7-20260101-v1:0")
    monkeypatch.setenv("PROMPT_DIR", "src/prompts/v1.0")


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
