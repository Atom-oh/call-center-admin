"""Bedrock Converse 호출 래퍼 (prompt caching 포함)."""

from __future__ import annotations

import os

import boto3

from lib.output_schema import ClassificationResult, parse_and_validate
from lib.prompts import PromptBundle

_DEFAULT_REGION = os.environ.get("AWS_REGION", "ap-northeast-2")


class BedrockAdapter:
    name: str
    version: str

    def __init__(self, model_id: str, bundle: PromptBundle, max_tokens: int = 1024) -> None:
        self.model_id = model_id
        self.bundle = bundle
        self.max_tokens = max_tokens
        self.name = f"bedrock-{model_id.replace('.', '-')}"
        self.version = bundle.prompt_version
        self._client = boto3.client("bedrock-runtime", region_name=_DEFAULT_REGION)

    def classify(self, masked_transcript: str) -> ClassificationResult:
        system = []
        for block in self.bundle.system_blocks:
            system.append({"text": block})
            system.append({"cachePoint": {"type": "default"}})

        resp = self._client.converse(
            modelId=self.model_id,
            system=system,
            messages=[
                {
                    "role": "user",
                    "content": [{"text": self.bundle.build_user_message(masked_transcript)}],
                }
            ],
            inferenceConfig={"maxTokens": self.max_tokens, "temperature": 0.0},
        )
        text = resp["output"]["message"]["content"][0]["text"]
        return parse_and_validate(text, self.bundle.valid_codes)
