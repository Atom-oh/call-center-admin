"""Verify Lambda — Sonnet으로 primary(Opus) 결과 cross-verify.

Input event (from classify Lambda):
  { callId, maskedBucket, maskedKey, modelId, promptVersion,
    classification: {대, 중, 소, confidence, reason, alternativesConsidered}, ... }

Output (additions):
  verifiedBy            : Sonnet model id
  verifyResult          : full ClassificationResult from Sonnet (asdict)
  verified              : "auto-confirmed" | "hitl-pending"
  status                : "confirmed" | "hitl-pending"
  modelPath             : [primary modelId, verify modelId]
"""

from __future__ import annotations

import dataclasses
import os
import sys
from pathlib import Path
from typing import Any

# Lambda zip 루트 = /var/task/, 그 안에 lib/ + lambdas/ + prompts/.
# TODO(phase2): lib/ + prompts/ 를 Lambda Layer로 분리.
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

import boto3

from lib.bedrock_client import BedrockAdapter
from lib.metrics import emit  # optional — emit verify-related metric
from lib.prompts import build_prompt_bundle

_VERIFY_MODEL_ID = os.environ["VERIFY_MODEL_ID"]
_PROMPT_DIR = Path(os.environ.get("PROMPT_DIR", "/var/task/prompts/v1.0"))
_RULES = (_PROMPT_DIR / "system_rules.md").read_text(encoding="utf-8")
_TREE = (_PROMPT_DIR / "taxonomy_tree.json").read_text(encoding="utf-8")
_BUNDLE = build_prompt_bundle(rules_md=_RULES, taxonomy_json=_TREE)
_ADAPTER = BedrockAdapter(model_id=_VERIFY_MODEL_ID, bundle=_BUNDLE)
_s3 = boto3.client("s3")


def _assert_primary_shape(primary: dict[str, Any]) -> None:
    """Fail loudly with a clear message if classify Lambda's output schema drifts.

    Without this, a missing key surfaces as a raw KeyError mid-handler, after we've
    already paid S3 GET + Bedrock invoke cost.
    """
    for k in ("대", "중", "소"):
        if not isinstance(primary.get(k), dict) or "code" not in primary[k]:
            raise ValueError(
                f"primary classification missing {k}.code — classify Lambda output schema drift?"
            )


def handler(event: dict[str, Any], _ctx: Any) -> dict[str, Any]:
    # Hard-fail if classify Lambda did not populate modelId. verify must never
    # run before classify, so this is a contract violation worth surfacing.
    primary_model_id = event["modelId"]
    primary = event["classification"]
    _assert_primary_shape(primary)

    masked = (
        _s3.get_object(Bucket=event["maskedBucket"], Key=event["maskedKey"])["Body"].read().decode()
    )
    secondary = _ADAPTER.classify(masked)

    same = (
        primary["대"]["code"] == secondary.대.code
        and primary["중"]["code"] == secondary.중.code
        and primary["소"]["code"] == secondary.소.code
    )

    if same:
        verified = "auto-confirmed"
        status = "confirmed"
    else:
        verified = "hitl-pending"
        status = "hitl-pending"

    # "agree" / "disagree" reads more naturally in CloudWatch Insights than
    # str(True) / str(False).
    emit("classification.verifyTriggered", 1.0, agreement="agree" if same else "disagree")

    return {
        **event,
        "verifiedBy": _VERIFY_MODEL_ID,
        "verifyResult": dataclasses.asdict(secondary),
        "verified": verified,
        "status": status,
        "modelPath": [primary_model_id, _VERIFY_MODEL_ID],
    }
