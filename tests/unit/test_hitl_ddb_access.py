"""HITL UI DDB access helpers — 단위 테스트 (spec §6.1).

각 함수가 spec §2.2 의 query 패턴을 정확히 따르는지 검증.
특히 ADR-008 (ASCII GSI 명 + 한국어 attribute placeholder) 와
ADR-003 (PII 추가 진입 경로 차단) 를 가드한다.

모듈 import 패턴: src/hitl_ui/hitl_lib/ 가 sys.path 위에 올라가지 않으므로
fixture 에서 직접 sys.path.insert + 환경변수 + sys.modules.pop.
패키지명이 `hitl_lib` 인 것은 root src/lib/ 와 이름 충돌을 피하기 위함.
"""

from __future__ import annotations

import sys
from pathlib import Path

import boto3
import pytest
from moto import mock_aws

# Make src/hitl_ui visible — same trick the runtime container uses.
_HITL_ROOT = Path(__file__).parent.parent.parent / "src" / "hitl_ui"
if str(_HITL_ROOT) not in sys.path:
    sys.path.insert(0, str(_HITL_ROOT))


@pytest.fixture
def ddb_table(monkeypatch):
    """Stand up the consult-results DDB table with 3 GSIs (matches storage module)."""
    monkeypatch.setenv("AWS_DEFAULT_REGION", "ap-northeast-2")
    monkeypatch.setenv("DDB_TABLE", "callcenter-test-consult-results")
    # Module-level _table cache: force fresh import each test.
    sys.modules.pop("hitl_lib.ddb_access", None)

    with mock_aws():
        ddb = boto3.client("dynamodb", region_name="ap-northeast-2")
        ddb.create_table(
            TableName="callcenter-test-consult-results",
            BillingMode="PAY_PER_REQUEST",
            AttributeDefinitions=[
                {"AttributeName": "callId", "AttributeType": "S"},
                {"AttributeName": "status", "AttributeType": "S"},
                {"AttributeName": "classifiedAt", "AttributeType": "S"},
                {"AttributeName": "agentId", "AttributeType": "S"},
                {"AttributeName": "category_대code", "AttributeType": "S"},
            ],
            KeySchema=[{"AttributeName": "callId", "KeyType": "HASH"}],
            GlobalSecondaryIndexes=[
                {
                    "IndexName": "status-classifiedAt-index",
                    "KeySchema": [
                        {"AttributeName": "status", "KeyType": "HASH"},
                        {"AttributeName": "classifiedAt", "KeyType": "RANGE"},
                    ],
                    "Projection": {"ProjectionType": "ALL"},
                },
                {
                    "IndexName": "agentId-classifiedAt-index",
                    "KeySchema": [
                        {"AttributeName": "agentId", "KeyType": "HASH"},
                        {"AttributeName": "classifiedAt", "KeyType": "RANGE"},
                    ],
                    "Projection": {"ProjectionType": "ALL"},
                },
                {
                    "IndexName": "category-daecode-classifiedAt-index",
                    "KeySchema": [
                        {"AttributeName": "category_대code", "KeyType": "HASH"},
                        {"AttributeName": "classifiedAt", "KeyType": "RANGE"},
                    ],
                    "Projection": {"ProjectionType": "ALL"},
                },
            ],
        )
        # Put a few rows covering the test cases.
        ddb.put_item(
            TableName="callcenter-test-consult-results",
            Item={
                "callId": {"S": "call_pending_001"},
                "agentId": {"S": "A1"},
                "classifiedAt": {"S": "2026-05-27T10:00:00Z"},
                "status": {"S": "hitl-pending"},
                "category_대code": {"S": "CS_CENTER_CONSULT_TYPE_PAY_NONEY"},
                "category_대name": {"S": "페이머니"},
                "category_중code": {"S": "M1"},
                "category_중name": {"S": "중분류"},
                "category_소code": {"S": "S1"},
                "category_소name": {"S": "소분류"},
                "confidence": {"N": "0.55"},
                "reason": {"S": "원본 reason"},
            },
        )
        ddb.put_item(
            TableName="callcenter-test-consult-results",
            Item={
                "callId": {"S": "call_other_001"},
                "agentId": {"S": "A2"},
                "classifiedAt": {"S": "2026-05-27T11:00:00Z"},
                "status": {"S": "confirmed"},
                "category_대code": {"S": "CS_CENTER_CONSULT_TYPE_PAY_NONEY"},
                "category_대name": {"S": "페이머니"},
                "category_중code": {"S": "M2"},
                "category_중name": {"S": "중분류"},
                "category_소code": {"S": "S2"},
                "category_소name": {"S": "소분류"},
                "confidence": {"N": "0.95"},
                "reason": {"S": "원본 reason 2"},
            },
        )
        yield


def test_list_review_queue_uses_status_index(ddb_table) -> None:
    """spec §2.2: review queue uses status-classifiedAt GSI + status placeholder."""
    from hitl_lib.ddb_access import list_review_queue

    items, _last_key = list_review_queue(limit=10)
    call_ids = sorted(it["callId"] for it in items)
    assert call_ids == ["call_pending_001"], (
        f"expected only the hitl-pending row, got: {call_ids!r}"
    )


def test_search_by_category_uses_ascii_index_name(ddb_table) -> None:
    """ADR-008 guard: the GSI name must be ASCII (`category-daecode-`), the
    DDB attribute remains Korean (`category_대code`). The query layer must
    use ExpressionAttributeNames to bridge the two."""
    from hitl_lib.ddb_access import search_by_category

    items = search_by_category("CS_CENTER_CONSULT_TYPE_PAY_NONEY")
    assert len(items) == 2, f"expected 2 rows for NONEY, got {len(items)}"
    assert all(it["category_대code"] == "CS_CENTER_CONSULT_TYPE_PAY_NONEY" for it in items)


def test_search_by_category_preserves_xlsx_code(ddb_table) -> None:
    """ADR-004 guard: the xlsx code identifier (NONEY) is the query key verbatim.

    If a future linter rewrites this to MONEY, this test fails — protecting the
    downstream RPA join key.
    """
    from hitl_lib.ddb_access import search_by_category

    # NONEY must yield results; MONEY must yield nothing because the DDB stores NONEY.
    assert search_by_category("CS_CENTER_CONSULT_TYPE_PAY_NONEY"), "NONEY query lost results"
    assert not search_by_category("CS_CENTER_CONSULT_TYPE_PAY_MONEY"), (
        "MONEY query unexpectedly returned rows — was the code corrected?"
    )


def test_search_by_agent_uses_agent_index(ddb_table) -> None:
    """spec §2.2: agent search uses the agentId GSI."""
    from hitl_lib.ddb_access import search_by_agent

    items = search_by_agent("A1")
    assert [it["callId"] for it in items] == ["call_pending_001"]


def test_get_call_uses_base_table(ddb_table) -> None:
    """spec §2.2: single-row fetch uses base GetItem, not a GSI."""
    from hitl_lib.ddb_access import get_call

    item = get_call("call_pending_001")
    assert item is not None
    assert item["callId"] == "call_pending_001"
    assert get_call("nonexistent") is None


def test_update_correction_writes_status_and_codes(ddb_table) -> None:
    """spec §2.1 corrected action: update sets status + 3 category codes only."""
    from hitl_lib.ddb_access import get_call, update_correction

    update_correction(
        "call_pending_001",
        {"대code": "X1", "중code": "X2", "소code": "X3"},
        corrected_by="ops@example.com",
    )
    item = get_call("call_pending_001")
    assert item is not None
    assert item["status"] == "hitl-corrected"
    assert item["category_대code"] == "X1"
    assert item["category_중code"] == "X2"
    assert item["category_소code"] == "X3"
    assert item["correctedBy"] == "ops@example.com"


def test_update_correction_does_not_touch_reason(ddb_table) -> None:
    """ADR-003 guard: HITL UI must NOT introduce new free text into the `reason`
    column. The original (sanitized) reason from persist Lambda is preserved
    as-is. If a future change adds reason to the update expression, this test
    fails — preventing Layer-3 PII guard bypass.
    """
    from hitl_lib.ddb_access import get_call, update_correction

    before = get_call("call_pending_001")
    assert before is not None
    original_reason = before["reason"]

    update_correction(
        "call_pending_001",
        {"대code": "Y1", "중code": "Y2", "소code": "Y3"},
        corrected_by="ops@example.com",
    )
    after = get_call("call_pending_001")
    assert after is not None
    assert after["reason"] == original_reason, (
        f"reason changed from {original_reason!r} to {after['reason']!r} — "
        "ADR-003 Layer-3 PII guard would be bypassed"
    )


def test_update_correction_does_not_trigger_sfn(ddb_table, monkeypatch) -> None:
    """ADR-007 guard: HITL correction is *outside* the SFN. The DDB UpdateItem
    must not invoke StepFunctions.start_execution.

    We patch boto3.client so that any sfn instantiation would be loud.
    """
    from unittest.mock import MagicMock

    import boto3 as boto3_real

    sfn_mock = MagicMock()
    original_client = boto3_real.client

    def _client(name, *args, **kwargs):
        if name == "stepfunctions":
            return sfn_mock
        return original_client(name, *args, **kwargs)

    monkeypatch.setattr("boto3.client", _client)

    from hitl_lib.ddb_access import update_correction

    update_correction(
        "call_pending_001",
        {"대code": "Z1", "중code": "Z2", "소code": "Z3"},
        corrected_by="ops@example.com",
    )
    assert sfn_mock.start_execution.call_count == 0, (
        "HITL correction triggered SFN.start_execution — violates ADR-007"
    )


def test_update_skip_writes_skipped_status(ddb_table) -> None:
    """spec §2.1 skip action: status only, codes unchanged."""
    from hitl_lib.ddb_access import get_call, update_skip

    before = get_call("call_pending_001")
    assert before is not None
    original_da = before["category_대code"]

    update_skip("call_pending_001", by="ops@example.com")

    after = get_call("call_pending_001")
    assert after is not None
    assert after["status"] == "hitl-skipped"
    # Codes are unchanged.
    assert after["category_대code"] == original_da
