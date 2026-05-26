"""Verify Lambda: Sonnet으로 1차 결과 검증.

IMPORTANT: handler를 절대 모듈 스코프에서 import 하지 마라. 각 테스트가 env 픽스처
적용 후 함수 내부에서 import 해야 sys.modules.pop 가 적용된다.
"""

import json
import sys
from unittest.mock import MagicMock, patch

import pytest


@pytest.fixture
def env(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", "ap-northeast-2")
    monkeypatch.setenv("AWS_REGION", "ap-northeast-2")
    monkeypatch.setenv("VERIFY_MODEL_ID", "anthropic.claude-sonnet-4-6-20260101-v1:0")
    monkeypatch.setenv("PROMPT_DIR", "src/prompts/v1.0")
    # 모듈-레벨 _ADAPTER 가 첫 import 시 bedrock 클라이언트를 캐시하므로,
    # 테스트마다 fresh patch가 적용되도록 handler 모듈을 unload 한다.
    sys.modules.pop("lambdas.verify.handler", None)


def _make_event(primary_codes: tuple[str, str, str], conf: float = 0.6) -> dict:
    return {
        "callId": "c1",
        "maskedBucket": "masked-test",
        "maskedKey": "k_masked.txt",
        "modelId": "anthropic.claude-opus-4-7-20260101-v1:0",
        "promptVersion": "v1.0",
        "classification": {
            "대": {"code": primary_codes[0], "name": "n"},
            "중": {"code": primary_codes[1], "name": "n"},
            "소": {"code": primary_codes[2], "name": "n"},
            "confidence": conf,
            "reason": "r",
            "alternativesConsidered": [],
        },
    }


def _fake_bedrock_response(codes: tuple[str, str, str], conf: float) -> dict:
    body = {
        "대": {"code": codes[0], "name": "n"},
        "중": {"code": codes[1], "name": "n"},
        "소": {"code": codes[2], "name": "n"},
        "confidence": conf,
        "reason": "v",
        "alternativesConsidered": [],
    }
    return {"output": {"message": {"content": [{"text": json.dumps(body, ensure_ascii=False)}]}}}


# Use any 3 real v1.0 codes (must be in taxonomy_tree.json's valid_codes set)
PRIMARY_CODES = (
    "CS_CENTER_CONSULT_TYPE_PAY_NONEY",
    "CS_CENTER_CONSULT_TYPE_PAY_NONEY_CHARGE_WITHDRAWAL",
    "CS_CENTER_CONSULT_TYPE_PAY_NONEY_CHARGE_WITHDRAWAL_CHARGE_DELAY",
)

DIFFERENT_CODES = (
    "CS_CENTER_CONSULT_TYPE_DONESTIC_ONLINE_PAYNENT",
    "CS_CENTER_CONSULT_TYPE_DONESTIC_ONLINE_PAYNENT",
    "CS_CENTER_CONSULT_TYPE_DONESTIC_ONLINE_PAYNENT",
)


def test_agreement_marks_auto_confirmed(env) -> None:
    """Sonnet이 Opus와 동일 분류 → verified=auto-confirmed, status=confirmed."""
    fake = MagicMock()
    fake.converse.return_value = _fake_bedrock_response(PRIMARY_CODES, 0.9)

    with (
        patch("lib.bedrock_client.boto3.client", return_value=fake),
        patch("lambdas.verify.handler._s3") as fake_s3,
    ):
        fake_s3.get_object.return_value = {"Body": MagicMock(read=lambda: b"agent: hi")}
        from lambdas.verify.handler import handler

        out = handler(_make_event(PRIMARY_CODES), None)
        assert out["verified"] == "auto-confirmed"
        assert out["status"] == "confirmed"
        assert out["modelPath"] == [
            "anthropic.claude-opus-4-7-20260101-v1:0",
            "anthropic.claude-sonnet-4-6-20260101-v1:0",
        ]


def test_disagreement_marks_hitl_pending(env) -> None:
    """Sonnet이 Opus와 다른 분류 → status=hitl-pending."""
    fake = MagicMock()
    fake.converse.return_value = _fake_bedrock_response(DIFFERENT_CODES, 0.7)

    with (
        patch("lib.bedrock_client.boto3.client", return_value=fake),
        patch("lambdas.verify.handler._s3") as fake_s3,
    ):
        fake_s3.get_object.return_value = {"Body": MagicMock(read=lambda: b"agent: hi")}
        from lambdas.verify.handler import handler

        out = handler(_make_event(PRIMARY_CODES), None)
        assert out["verified"] == "hitl-pending"
        assert out["status"] == "hitl-pending"


def test_verify_includes_secondary_result_in_output(env) -> None:
    """verify 결과 자체도 event에 포함되어 persist 단계가 modelPath / 비교 분석 활용 가능."""
    fake = MagicMock()
    fake.converse.return_value = _fake_bedrock_response(PRIMARY_CODES, 0.85)
    with (
        patch("lib.bedrock_client.boto3.client", return_value=fake),
        patch("lambdas.verify.handler._s3") as fake_s3,
    ):
        fake_s3.get_object.return_value = {"Body": MagicMock(read=lambda: b"agent: hi")}
        from lambdas.verify.handler import handler

        out = handler(_make_event(PRIMARY_CODES), None)
        assert "verifyResult" in out
        assert out["verifyResult"]["confidence"] == 0.85
        assert out["verifyResult"]["대"]["code"] == PRIMARY_CODES[0]
        assert out["verifiedBy"] == "anthropic.claude-sonnet-4-6-20260101-v1:0"
