"""Persist 단계 헬퍼: 출력 후처리 PII sweep + DDB item builder."""

from __future__ import annotations

import time
from typing import Any

from lib.pii_regex import mask


def sanitize_text(text: str | None) -> str:
    """LLM이 만들어 낼 수 있는 합성 PII까지 한 번 더 정규식으로 거른다."""
    if not text:
        return ""
    sanitized, _ = mask(text)
    return sanitized


def build_ddb_item(event: dict[str, Any]) -> dict[str, Any]:
    """SFN 마지막 단계 event를 DynamoDB record로 직렬화.

    PR2 schema 참조: hash key = callId, GSI = status / agentId / category_대code.
    """
    c = event["classification"]
    now = int(time.time())
    return {
        "callId": event["callId"],
        "agentId": event["agentId"],
        "startedAt": event["startedAt"],
        "durationSec": event["durationSec"],
        "rawSttRef": f"s3://{event['rawBucket']}/{event['rawKey']}",
        "piiMaskedTextRef": f"s3://{event['maskedBucket']}/{event['maskedKey']}",
        "category_대code": c["대"]["code"],
        "category_대name": c["대"]["name"],
        "category_중code": c["중"]["code"],
        "category_중name": c["중"]["name"],
        "category_소code": c["소"]["code"],
        "category_소name": c["소"]["name"],
        "confidence": c["confidence"],
        "reason": sanitize_text(c.get("reason"))[:2000],
        "alternativesConsidered": [
            {"code": a.get("code", ""), "why_rejected": sanitize_text(a.get("why_rejected"))[:500]}
            for a in c.get("alternativesConsidered", [])
        ],
        # Filter None defensively — if both modelPath and modelId are missing,
        # store an empty list rather than [None] which downstream analytics chokes on.
        "modelPath": [m for m in event.get("modelPath", [event.get("modelId")]) if m],
        "promptVersion": event.get("promptVersion", "v1.0"),
        "verified": event.get("verified", "auto-high"),
        "status": event.get("status", "confirmed"),
        "classifiedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
        "ttlEpoch": now + 365 * 24 * 3600,
    }
