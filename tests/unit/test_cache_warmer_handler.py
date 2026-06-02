"""cache_warmer Lambda + BedrockAdapter.warm() 단위 테스트 (ADR-002).

핵심 가드: warm() 이 classify() 와 **동일한 system 블록(cache key)** 을 보내고,
temperature 를 넣지 않으며(ADR-014), parse_and_validate 를 하지 않는다.
"""

from __future__ import annotations

import json
import sys
from unittest.mock import MagicMock, patch


def _bundle():
    from lib.prompts import build_prompt_bundle

    taxonomy_json = (
        '[{"code":"A","name":"대","level":1},'
        '{"code":"A_B","name":"중","level":2},'
        '{"code":"A_B_C","name":"소","level":3}]'
    )
    return build_prompt_bundle(rules_md="rules", taxonomy_json=taxonomy_json)


def test_warm_uses_same_system_blocks_as_classify(monkeypatch) -> None:
    """ADR-002: warm() 과 classify() 의 system array 가 동일해야 cache key 일치."""
    monkeypatch.setenv("AWS_REGION", "ap-northeast-2")
    fake = MagicMock()
    fake.converse.return_value = {"usage": {"cacheReadInputTokens": 123}}

    with patch("lib.bedrock_client.boto3.client", return_value=fake):
        from lib.bedrock_client import BedrockAdapter

        ad = BedrockAdapter("global.anthropic.claude-opus-4-7", _bundle())
        warm_system = ad._build_system()
        ad.warm()

    sent_system = fake.converse.call_args.kwargs["system"]
    assert sent_system == warm_system
    # 2-breakpoint: text, cachePoint, text, cachePoint
    assert [next(iter(b.keys())) for b in sent_system] == ["text", "cachePoint", "text", "cachePoint"]


def test_warm_no_temperature(monkeypatch) -> None:
    """ADR-014: warm() inferenceConfig 에 temperature/top_p/top_k 없음."""
    monkeypatch.setenv("AWS_REGION", "ap-northeast-2")
    fake = MagicMock()
    fake.converse.return_value = {"usage": {}}
    with patch("lib.bedrock_client.boto3.client", return_value=fake):
        from lib.bedrock_client import BedrockAdapter

        BedrockAdapter("global.anthropic.claude-opus-4-7", _bundle()).warm()
    ic = fake.converse.call_args.kwargs["inferenceConfig"]
    assert "temperature" not in ic and "top_p" not in ic and "top_k" not in ic
    assert ic["maxTokens"] == 1


def test_warm_returns_usage(monkeypatch) -> None:
    monkeypatch.setenv("AWS_REGION", "ap-northeast-2")
    fake = MagicMock()
    fake.converse.return_value = {"usage": {"cacheReadInputTokens": 9000}}
    with patch("lib.bedrock_client.boto3.client", return_value=fake):
        from lib.bedrock_client import BedrockAdapter

        usage = BedrockAdapter("global.anthropic.claude-opus-4-7", _bundle()).warm()
    assert usage["cacheReadInputTokens"] == 9000


def test_handler_emits_warm_metrics(monkeypatch) -> None:
    """handler 가 cache.warm.invoked + cacheReadTokens EMF emit."""
    monkeypatch.setenv("AWS_REGION", "ap-northeast-2")
    monkeypatch.setenv("MODEL_ID", "global.anthropic.claude-opus-4-7")
    monkeypatch.setenv("PROMPT_DIR", "src/prompts/v1.0")
    sys.modules.pop("lambdas.cache_warmer.handler", None)

    fake = MagicMock()
    fake.converse.return_value = {"usage": {"cacheReadInputTokens": 4242}}
    with patch("lib.bedrock_client.boto3.client", return_value=fake):
        import contextlib
        import io

        from lambdas.cache_warmer.handler import handler

        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            out = handler({}, None)

    assert out["warmed"] is True
    assert out["cacheReadInputTokens"] == 4242
    emitted = buf.getvalue()
    assert "cache.warm.invoked" in emitted
    assert "cache.warm.cacheReadTokens" in emitted
    # emit 은 valid JSON 라인
    metric_lines = [
        line for line in emitted.splitlines() if "cache.warm" in line and line.startswith("{")
    ]
    assert metric_lines, "expected EMF JSON lines"
    json.loads(metric_lines[0])
