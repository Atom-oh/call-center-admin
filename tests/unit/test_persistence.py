from lib.persistence import build_ddb_item, sanitize_text


def test_sanitize_text_strips_pii() -> None:
    text = "고객님 010-1234-5678 충전 오류"
    out = sanitize_text(text)
    assert "[MASKED_PHONE]" in out
    assert "010-1234-5678" not in out


def test_sanitize_text_handles_none() -> None:
    assert sanitize_text(None) == ""
    assert sanitize_text("") == ""


def test_build_ddb_item_has_all_required_fields() -> None:
    classification = {
        "대": {"code": "X", "name": "x"},
        "중": {"code": "Y", "name": "y"},
        "소": {"code": "Z", "name": "z"},
        "confidence": 0.9,
        "reason": "고객 010-1111-2222 호소",
        "alternativesConsidered": [{"code": "X2", "why_rejected": "전화 010-9999-9999 언급"}],
    }
    event = {
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
        "classification": classification,
        "verified": "auto-high",
        "status": "confirmed",
        "modelPath": ["opus"],
    }
    item = build_ddb_item(event)
    assert item["callId"] == "c1"
    # PII sanitization on reason + alternatives why_rejected
    assert "010-1111-2222" not in item["reason"]
    assert "010-9999-9999" not in item["alternativesConsidered"][0]["why_rejected"]
    # Required category fields
    assert item["category_대code"] == "X"
    assert item["category_중code"] == "Y"
    assert item["category_소code"] == "Z"
    assert item["category_대name"] == "x"
    # Numeric
    assert item["confidence"] == 0.9
    # TTL
    assert item["ttlEpoch"] > 0
    # Audit fields
    assert item["promptVersion"] == "v1.0"
    assert item["modelPath"] == ["opus"]
    assert item["rawSttRef"] == "s3://raw/k.json"
    assert item["piiMaskedTextRef"] == "s3://masked/k_masked.txt"


def test_build_ddb_item_caps_reason_length() -> None:
    """reason ≤ 2000 chars (DDB attribute size guard)."""
    event = {
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
            "confidence": 0.5,
            "reason": "x" * 5000,
            "alternativesConsidered": [],
        },
        "verified": "auto-high",
        "status": "confirmed",
    }
    item = build_ddb_item(event)
    assert len(item["reason"]) <= 2000
