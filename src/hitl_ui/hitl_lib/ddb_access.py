"""DynamoDB query / update helpers for the HITL UI.

Spec: docs/superpowers/specs/2026-05-27-hitl-ui-design.md §2.2
ADR guards:
  ADR-003 — `update_correction` and `update_skip` never write to the `reason`
            column. The original sanitized reason from persist Lambda is
            preserved as-is; HITL UI cannot introduce new PII into DDB.
  ADR-004 — Category codes (NONEY / PAYNENT etc.) are passed through as-is.
  ADR-007 — HITL decision is *outside* the Step Functions pipeline. These
            helpers do not invoke StepFunctions.
  ADR-008 — GSI index names are ASCII (`category-daecode-…`); the underlying
            attribute is Korean (`category_대code`). The query layer bridges
            with ExpressionAttributeNames placeholders.
"""

from __future__ import annotations

import os
from datetime import datetime, timezone
from typing import Any

import boto3
from botocore.exceptions import ClientError

from hitl_lib.audit import emit_audit

_ddb = boto3.resource("dynamodb")
_table = _ddb.Table(os.environ["DDB_TABLE"])


class AlreadyProcessedError(RuntimeError):
    """Raised when an HITL write loses the first-write-wins optimistic lock.

    The row was no longer status=hitl-pending at write time — another reviewer
    (or a stale Streamlit rerun) already corrected/skipped it. ADR-011: first
    write wins. The Streamlit page catches this and tells the user the row was
    handled by someone else, instead of silently clobbering (last-write-wins).
    """

    def __init__(self, call_id: str) -> None:
        self.call_id = call_id
        super().__init__(f"call {call_id} already processed by another reviewer")


def list_review_queue(
    limit: int = 50, last_key: dict[str, Any] | None = None
) -> tuple[list[dict[str, Any]], dict[str, Any] | None]:
    """Return one page of `status=hitl-pending` rows + the next pagination key."""
    kwargs: dict[str, Any] = {
        "IndexName": "status-classifiedAt-index",
        "KeyConditionExpression": "#s = :pending",
        "ExpressionAttributeNames": {"#s": "status"},
        "ExpressionAttributeValues": {":pending": "hitl-pending"},
        "Limit": limit,
    }
    if last_key:
        kwargs["ExclusiveStartKey"] = last_key
    resp = _table.query(**kwargs)
    return resp["Items"], resp.get("LastEvaluatedKey")


def search_by_agent(agent_id: str, limit: int = 100) -> list[dict[str, Any]]:
    """Query the agentId GSI — returns all rows for the given agentId."""
    resp = _table.query(
        IndexName="agentId-classifiedAt-index",
        KeyConditionExpression="agentId = :a",
        ExpressionAttributeValues={":a": agent_id},
        Limit=limit,
    )
    return resp["Items"]


def search_by_category(da_code: str, limit: int = 100) -> list[dict[str, Any]]:
    """Query the category daecode GSI — ADR-008 placeholder bridges ASCII index
    name to the Korean attribute `category_대code`. ADR-004: the value (NONEY etc)
    is passed through verbatim.
    """
    resp = _table.query(
        IndexName="category-daecode-classifiedAt-index",
        KeyConditionExpression="#daecode = :c",
        ExpressionAttributeNames={"#daecode": "category_대code"},
        ExpressionAttributeValues={":c": da_code},
        Limit=limit,
    )
    return resp["Items"]


def get_call(call_id: str) -> dict[str, Any] | None:
    resp = _table.get_item(Key={"callId": call_id})
    return resp.get("Item")


def update_correction(call_id: str, corrected_codes: dict[str, str], corrected_by: str) -> None:
    """Record an HITL correction (ADR-011 first-write-wins optimistic lock).

    Only writes status / verified / correctedAt / correctedBy + 3 category codes.
    The `reason` column is intentionally NOT touched — preserving the sanitized
    text from persist Lambda (ADR-003 Layer-3 PII guard).

    The UpdateItem is conditional on the row still being status=hitl-pending; if
    another reviewer already corrected/skipped it, DynamoDB rejects the write and
    this raises AlreadyProcessedError (the second writer loses, no clobber).
    """
    try:
        _table.update_item(
            Key={"callId": call_id},
            UpdateExpression=(
                "SET #s = :s, verified = :v, correctedAt = :ca, correctedBy = :cb, "
                "#daecode = :dc, #jungcode = :mc, #socode = :sc"
            ),
            ConditionExpression="#s = :pending",
            ExpressionAttributeNames={
                "#s": "status",
                "#daecode": "category_대code",
                "#jungcode": "category_중code",
                "#socode": "category_소code",
            },
            ExpressionAttributeValues={
                ":s": "hitl-corrected",
                ":v": "hitl-corrected",
                ":ca": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),  # noqa: UP017
                ":cb": corrected_by,
                ":dc": corrected_codes["대code"],
                ":mc": corrected_codes["중code"],
                ":sc": corrected_codes["소code"],
                ":pending": "hitl-pending",
            },
        )
    except ClientError as ex:
        if ex.response["Error"]["Code"] == "ConditionalCheckFailedException":
            raise AlreadyProcessedError(call_id) from ex
        raise
    # M3: audit AFTER the write applies, so the trail records only effective
    # changes — a rejected lock raises above and emits nothing.
    emit_audit(
        "hitl.correction",
        user=corrected_by,
        call_id=call_id,
        daecode=corrected_codes.get("대code"),
    )


def update_skip(call_id: str, by: str) -> None:
    """Mark the row as hitl-skipped — codes unchanged, only the status moves.

    Conditional on status=hitl-pending (ADR-011 first-write-wins); raises
    AlreadyProcessedError if another reviewer already handled the row.
    """
    try:
        _table.update_item(
            Key={"callId": call_id},
            UpdateExpression="SET #s = :s, correctedAt = :ca, correctedBy = :cb",
            ConditionExpression="#s = :pending",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={
                ":s": "hitl-skipped",
                ":ca": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),  # noqa: UP017
                ":cb": by,
                ":pending": "hitl-pending",
            },
        )
    except ClientError as ex:
        if ex.response["Error"]["Code"] == "ConditionalCheckFailedException":
            raise AlreadyProcessedError(call_id) from ex
        raise
    emit_audit("hitl.skip", user=by, call_id=call_id)
