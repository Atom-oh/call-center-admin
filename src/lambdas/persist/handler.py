"""Persist Lambda: PII sweep → DDB write + (optional) Firehose put."""
from __future__ import annotations

import json
import os
import sys
from decimal import Decimal
from pathlib import Path

# Lambda zip 루트 = /var/task/. TODO(phase2): lib/ → Lambda Layer.
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

import boto3
from botocore.exceptions import ClientError

from lib.metrics import emit
from lib.persistence import build_ddb_item

_ddb = boto3.resource("dynamodb")
_table = _ddb.Table(os.environ["DDB_TABLE"])
_firehose = boto3.client("firehose")
_FIREHOSE_NAME = os.environ.get("FIREHOSE_NAME", "")


def _to_decimal(o):  # type: ignore[no-untyped-def]
    if isinstance(o, float):
        return Decimal(str(o))
    if isinstance(o, dict):
        return {k: _to_decimal(v) for k, v in o.items()}
    if isinstance(o, list):
        return [_to_decimal(v) for v in o]
    return o


def handler(event: dict, _ctx) -> dict:
    item = build_ddb_item(event)
    try:
        _table.put_item(
            Item=_to_decimal(item),
            ConditionExpression="attribute_not_exists(callId) OR promptVersion = :pv",
            ExpressionAttributeValues={":pv": item["promptVersion"]},
        )
    except ClientError as ex:
        # ConditionalCheckFailedException happens when the same callId was already
        # written under a DIFFERENT promptVersion (i.e., backfill / reclassification
        # attempt). Treat as "skip silently" rather than retrying 3x and DLQ'ing —
        # the older record is preserved by design. Surface as a metric so PR9
        # observability can chart this.
        code = ex.response.get("Error", {}).get("Code", "")
        if code == "ConditionalCheckFailedException":
            emit("classification.skippedExisting", 1.0, 대code=item["category_대code"])
            return {**event, "persisted": False, "skipReason": "promptVersion-conflict"}
        raise
    if _FIREHOSE_NAME:
        _firehose.put_record(
            DeliveryStreamName=_FIREHOSE_NAME,
            Record={"Data": (json.dumps(item, default=str) + "\n").encode("utf-8")},
        )
    emit("classification.processed", 1.0, 대code=item["category_대code"])
    emit("classification.confidence", item["confidence"], unit="None", 대code=item["category_대code"])
    return {**event, "persisted": True}
