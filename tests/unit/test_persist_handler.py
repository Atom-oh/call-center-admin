"""Persist Lambda: DDB write (and Firehose put if FIREHOSE_NAME set)."""

import sys

import boto3
import pytest
from moto import mock_aws


@pytest.fixture
def env(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", "ap-northeast-2")
    monkeypatch.setenv("DDB_TABLE", "callcenter-dev-consult-results")
    monkeypatch.setenv("FIREHOSE_NAME", "")
    sys.modules.pop("lambdas.persist.handler", None)


def _event() -> dict:
    return {
        "callId": "c1",
        "agentId": "a1",
        "startedAt": "2026-05-22T00:00:00Z",
        "durationSec": 60,
        "rawBucket": "raw",
        "rawKey": "k.json",
        "maskedBucket": "masked",
        "maskedKey": "k_masked.txt",
        "modelId": "opus",
        "promptVersion": "v1.0",
        "classification": {
            "대": {"code": "X", "name": "x"},
            "중": {"code": "Y", "name": "y"},
            "소": {"code": "Z", "name": "z"},
            "confidence": 0.9,
            "reason": "r",
            "alternativesConsidered": [],
        },
        "verified": "auto-high",
        "status": "confirmed",
    }


@mock_aws
def test_persist_writes_ddb(env) -> None:
    ddb = boto3.client("dynamodb", region_name="ap-northeast-2")
    ddb.create_table(
        TableName="callcenter-dev-consult-results",
        KeySchema=[{"AttributeName": "callId", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "callId", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )
    from lambdas.persist.handler import handler

    out = handler(_event(), None)
    assert out["persisted"] is True

    got = ddb.get_item(TableName="callcenter-dev-consult-results", Key={"callId": {"S": "c1"}})
    assert "Item" in got
    assert got["Item"]["category_대code"]["S"] == "X"
    assert got["Item"]["status"]["S"] == "confirmed"


@mock_aws
def test_persist_idempotent_same_prompt_version(env) -> None:
    """동일 promptVersion으로 두 번 put_item 호출해도 실패하지 않아야 한다 (재시도 안전)."""
    ddb = boto3.client("dynamodb", region_name="ap-northeast-2")
    ddb.create_table(
        TableName="callcenter-dev-consult-results",
        KeySchema=[{"AttributeName": "callId", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "callId", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )
    from lambdas.persist.handler import handler

    handler(_event(), None)
    # second call with same promptVersion — should still succeed
    out2 = handler(_event(), None)
    assert out2["persisted"] is True


@mock_aws
def test_persist_skips_firehose_when_name_empty(env, monkeypatch) -> None:
    """FIREHOSE_NAME 미설정 시 firehose.put_record 호출하지 않는다."""
    monkeypatch.setenv("FIREHOSE_NAME", "")
    sys.modules.pop("lambdas.persist.handler", None)

    ddb = boto3.client("dynamodb", region_name="ap-northeast-2")
    ddb.create_table(
        TableName="callcenter-dev-consult-results",
        KeySchema=[{"AttributeName": "callId", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "callId", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )

    # No assertion needed — would crash if firehose were called against non-existent stream
    from lambdas.persist.handler import handler
    out = handler(_event(), None)
    assert out["persisted"] is True


@mock_aws
def test_persist_skips_silently_on_prompt_version_conflict(env) -> None:
    """동일 callId에 다른 promptVersion으로 재처리 시 silent skip + 메트릭만 emit."""
    ddb = boto3.client("dynamodb", region_name="ap-northeast-2")
    ddb.create_table(
        TableName="callcenter-dev-consult-results",
        KeySchema=[{"AttributeName": "callId", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "callId", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )
    from lambdas.persist.handler import handler

    # First write with v1.0 succeeds
    handler(_event(), None)
    # Re-process same callId with v2.0 — should not raise, returns persisted=False
    evt2 = _event()
    evt2["promptVersion"] = "v2.0"
    out = handler(evt2, None)
    assert out["persisted"] is False
    assert out["skipReason"] == "promptVersion-conflict"
