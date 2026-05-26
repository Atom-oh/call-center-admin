"""Bedrock 응답 JSON 검증/파싱."""
from __future__ import annotations

import json
import re
from dataclasses import dataclass


class ValidationError(Exception):
    pass


@dataclass
class CategoryLabel:
    code: str
    name: str


@dataclass
class Alternative:
    code: str
    why_rejected: str


@dataclass
class ClassificationResult:
    대: CategoryLabel
    중: CategoryLabel
    소: CategoryLabel
    confidence: float
    reason: str
    alternativesConsidered: list[Alternative]


_MD_FENCE = re.compile(r"^```(?:json)?\s*(.*?)\s*```$", re.DOTALL)


def _strip_markdown_fence(text: str) -> str:
    m = _MD_FENCE.match(text.strip())
    return m.group(1) if m else text


def parse_and_validate(raw: str, valid_codes: set[str]) -> ClassificationResult:
    text = _strip_markdown_fence(raw)
    try:
        data = json.loads(text)
    except json.JSONDecodeError as ex:
        raise ValidationError(f"invalid JSON: {ex}") from ex

    # Top-level must be a JSON object — defend against array/scalar/null payloads
    # (hallucination, prompt-injection recovery). Without this guard, downstream
    # `data.keys()` raises AttributeError which SFN Catch cannot classify cleanly.
    if not isinstance(data, dict):
        raise ValidationError(f"top-level JSON must be object, got {type(data).__name__}")

    required = {"대", "중", "소", "confidence", "reason", "alternativesConsidered"}
    missing = required - data.keys()
    if missing:
        raise ValidationError(f"missing keys: {missing}")

    for k in ("대", "중", "소"):
        node = data[k]
        if not isinstance(node, dict) or "code" not in node or "name" not in node:
            raise ValidationError(f"{k} must have code+name")
        if node["code"] not in valid_codes:
            raise ValidationError(f"unknown code in {k}: {node['code']}")

    conf = data["confidence"]
    # Reject bool explicitly — Python treats bool as int subclass so `True` would
    # otherwise satisfy `isinstance(int, float)` and `0 <= True <= 1`.
    if isinstance(conf, bool) or not isinstance(conf, (int, float)) or not 0 <= conf <= 1:
        raise ValidationError(f"confidence out of range: {conf}")

    alternatives = []
    for a in data.get("alternativesConsidered", []):
        if a.get("code") and a["code"] not in valid_codes:
            raise ValidationError(f"unknown code in alternatives: {a['code']}")
        alternatives.append(Alternative(code=a.get("code", ""), why_rejected=a.get("why_rejected", "")))

    return ClassificationResult(
        대=CategoryLabel(**data["대"]),
        중=CategoryLabel(**data["중"]),
        소=CategoryLabel(**data["소"]),
        confidence=float(conf),
        reason=data["reason"],
        alternativesConsidered=alternatives,
    )
