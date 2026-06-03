"""EventBridge cron 으로 주기 호출 — Bedrock prompt cache 워밍 (ADR-002).

classify Lambda 와 동일한 2-breakpoint system 블록 (system_rules + taxonomy_tree)
을 같은 MODEL_ID 로 호출하여 prompt cache 를 warm 상태로 유지한다. cold-cache 시
input token 비용 spike 를 줄이는 OPTIONAL 기능 (Terraform 에서 default-off).
"""

from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Any

# Lambda zip 루트 = /var/task/, 그 안에 lib/ + lambdas/ + prompts/
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from lib.bedrock_client import BedrockAdapter
from lib.metrics import emit
from lib.prompts import build_prompt_bundle

_MODEL_ID = os.environ["MODEL_ID"]
_PROMPT_DIR = Path(os.environ.get("PROMPT_DIR", "/var/task/prompts/v1.0"))
_RULES = (_PROMPT_DIR / "system_rules.md").read_text(encoding="utf-8")
_TREE = (_PROMPT_DIR / "taxonomy_tree.json").read_text(encoding="utf-8")
_BUNDLE = build_prompt_bundle(rules_md=_RULES, taxonomy_json=_TREE)
_ADAPTER = BedrockAdapter(model_id=_MODEL_ID, bundle=_BUNDLE)


def handler(_event: dict[str, Any], _ctx: Any) -> dict[str, Any]:
    usage = _ADAPTER.warm()
    cache_read = int(usage.get("cacheReadInputTokens", 0))
    emit("cache.warm.invoked", 1.0, promptVersion=_BUNDLE.prompt_version)
    emit(
        "cache.warm.cacheReadTokens",
        float(cache_read),
        unit="None",
        promptVersion=_BUNDLE.prompt_version,
    )
    return {
        "warmed": True,
        "modelId": _MODEL_ID,
        "promptVersion": _BUNDLE.prompt_version,
        "cacheReadInputTokens": cache_read,
    }
