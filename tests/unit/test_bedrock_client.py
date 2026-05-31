"""BedrockAdapter 회귀 테스트 (ADR-014).

Opus 4.7+ 는 inferenceConfig 의 temperature 파라미터를 받지 않는다
(ValidationException). 본 테스트는 converse 호출의 inferenceConfig 에
temperature key 가 없음을 가드한다 — 미래에 무심코 되돌리는 것 차단.
"""

from __future__ import annotations

from unittest.mock import MagicMock, patch


def _build_adapter():
    """Construct a BedrockAdapter with a minimal real PromptBundle."""
    from lib.prompts import build_prompt_bundle

    rules = "you are a classifier"
    # _serialize_taxonomy expects a flat list of nodes (level 1/2/3), not nested.
    taxonomy_json = (
        '[{"code":"A","name":"대","level":1},'
        '{"code":"A_B","name":"중","level":2},'
        '{"code":"A_B_C","name":"소","level":3}]'
    )
    bundle = build_prompt_bundle(rules_md=rules, taxonomy_json=taxonomy_json)
    from lib.bedrock_client import BedrockAdapter

    return BedrockAdapter(model_id="global.anthropic.claude-opus-4-7", bundle=bundle)


def _fake_converse_response() -> dict:
    body = (
        '{"대":{"code":"A","name":"대"},'
        '"중":{"code":"A_B","name":"중"},'
        '"소":{"code":"A_B_C","name":"소"},'
        '"confidence":0.9,"reason":"r","alternativesConsidered":[]}'
    )
    return {"output": {"message": {"content": [{"text": body}]}}}


def test_inference_config_has_no_temperature(monkeypatch) -> None:
    """ADR-014: converse() 의 inferenceConfig 에 temperature 가 있으면 안 된다."""
    monkeypatch.setenv("AWS_REGION", "ap-northeast-2")

    fake_client = MagicMock()
    fake_client.converse.return_value = _fake_converse_response()

    with patch("lib.bedrock_client.boto3.client", return_value=fake_client):
        adapter = _build_adapter()
        adapter.classify("agent: 안녕하세요")

    assert fake_client.converse.called, "converse must be invoked"
    inference_config = fake_client.converse.call_args.kwargs["inferenceConfig"]
    assert "temperature" not in inference_config, (
        "inferenceConfig must NOT contain temperature (Opus 4.7 ValidationException, ADR-014)"
    )
    assert "top_p" not in inference_config, "top_p also unsupported on Opus 4.7+"
    assert "top_k" not in inference_config, "top_k also unsupported on Opus 4.7+"
    # maxTokens stays — output length control is still valid.
    assert inference_config.get("maxTokens") == 1024


def test_max_tokens_still_passed(monkeypatch) -> None:
    """maxTokens 는 유지 — temperature 제거가 출력 길이 제어까지 없애면 안 됨."""
    monkeypatch.setenv("AWS_REGION", "ap-northeast-2")

    fake_client = MagicMock()
    fake_client.converse.return_value = _fake_converse_response()

    with patch("lib.bedrock_client.boto3.client", return_value=fake_client):
        adapter = _build_adapter()
        adapter.classify("agent: hi")

    inference_config = fake_client.converse.call_args.kwargs["inferenceConfig"]
    assert inference_config["maxTokens"] == 1024
