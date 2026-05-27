"""Step Functions task: read masked transcript, call Bedrock, return classification."""

from __future__ import annotations

import dataclasses
import os
import sys
from pathlib import Path
from typing import Any

# Lambda zip 루트 = /var/task/, 그 안에 lib/ + lambdas/ + prompts/
# TODO(phase2): lib/ + prompts/ 를 Lambda Layer로 분리.
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

import boto3

from lib.bedrock_client import BedrockAdapter
from lib.metrics import emit
from lib.prompts import build_prompt_bundle

_MODEL_ID = os.environ["MODEL_ID"]
_PROMPT_DIR = Path(os.environ.get("PROMPT_DIR", "/var/task/prompts/v1.0"))
_RULES = (_PROMPT_DIR / "system_rules.md").read_text(encoding="utf-8")
_TREE = (_PROMPT_DIR / "taxonomy_tree.json").read_text(encoding="utf-8")
_BUNDLE = build_prompt_bundle(rules_md=_RULES, taxonomy_json=_TREE)
_ADAPTER = BedrockAdapter(model_id=_MODEL_ID, bundle=_BUNDLE)
_s3 = boto3.client("s3")


def handler(event: dict[str, Any], _ctx: Any) -> dict[str, Any]:
    masked = (
        _s3.get_object(Bucket=event["maskedBucket"], Key=event["maskedKey"])["Body"].read().decode()
    )
    result = _ADAPTER.classify(masked)

    # PR9 / spec §2.1: classify-side EMF. Persist also emits classification.processed
    # post-DDB, but classify emits here too so a persist-side failure does not lose
    # the LLM-call signal. ADR-004: 대code dim value is the xlsx code verbatim
    # (NONEY / PAYNENT / ... must NOT be 'corrected').
    emit("classify.invoked", 1.0, 대code=result.대.code)
    emit("classify.confidence", float(result.confidence), unit="None", 대code=result.대.code)

    return {
        **event,
        "modelId": _MODEL_ID,
        "promptVersion": _BUNDLE.prompt_version,
        "classification": dataclasses.asdict(result),
    }
