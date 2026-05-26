"""Bedrock 응답 JSON 검증/파싱 단위 테스트."""
import pytest

from lib.output_schema import ClassificationResult, ValidationError, parse_and_validate


def test_valid_payload_parses() -> None:
    raw = """{
      "대": {"code": "CS_CENTER_CONSULT_TYPE_PAY_NONEY", "name": "페이머니"},
      "중": {"code": "CS_CENTER_CONSULT_TYPE_PAY_NONEY_CHARGE_WITHDRAWAL", "name": "충전/출금"},
      "소": {"code": "CS_CENTER_CONSULT_TYPE_PAY_NONEY_CHARGE_WITHDRAWAL_CHARGE_DELAY", "name": "충전 지연/오류"},
      "confidence": 0.88,
      "reason": "고객이 충전 오류를 호소함",
      "alternativesConsidered": []
    }"""
    valid_codes = {
        "CS_CENTER_CONSULT_TYPE_PAY_NONEY",
        "CS_CENTER_CONSULT_TYPE_PAY_NONEY_CHARGE_WITHDRAWAL",
        "CS_CENTER_CONSULT_TYPE_PAY_NONEY_CHARGE_WITHDRAWAL_CHARGE_DELAY",
    }
    result = parse_and_validate(raw, valid_codes)
    assert isinstance(result, ClassificationResult)
    assert result.대.code.startswith("CS_CENTER")
    assert 0 <= result.confidence <= 1


def test_invalid_code_rejected() -> None:
    raw = '{"대":{"code":"FAKE","name":"x"},"중":{"code":"FAKE","name":"x"},"소":{"code":"FAKE","name":"x"},"confidence":0.5,"reason":"r","alternativesConsidered":[]}'
    with pytest.raises(ValidationError) as ex:
        parse_and_validate(raw, valid_codes={"CS_X"})
    assert "FAKE" in str(ex.value)


def test_confidence_out_of_range() -> None:
    raw = '{"대":{"code":"x","name":"x"},"중":{"code":"x","name":"x"},"소":{"code":"x","name":"x"},"confidence":1.5,"reason":"r","alternativesConsidered":[]}'
    with pytest.raises(ValidationError):
        parse_and_validate(raw, valid_codes={"x"})


def test_handles_markdown_wrapped_json() -> None:
    raw = '```json\n{"대":{"code":"x","name":"x"},"중":{"code":"x","name":"x"},"소":{"code":"x","name":"x"},"confidence":0.7,"reason":"r","alternativesConsidered":[]}\n```'
    result = parse_and_validate(raw, valid_codes={"x"})
    assert result.confidence == 0.7
