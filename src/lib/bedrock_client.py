"""Bedrock Converse 호출 래퍼 (prompt caching 포함)."""

from __future__ import annotations

import os
from typing import Any

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

    def _build_system(self) -> list[dict[str, Any]]:
        # Bedrock Converse system blocks: text + cachePoint 항목이 같은 list에 섞임
        # (ADR-002 two-breakpoint). boto3-stubs 의 SystemContentBlockTypeDef 는 아직
        # cachePoint 를 명시적으로 정의하지 않으므로 strict mypy 회피용 Any 캐스트.
        # lib.bedrock_client 모듈은 pyproject.toml [tool.mypy.overrides] 에서 일부 완화.
        # classify() 와 warm() 이 이 메서드를 공유 → 동일 cache key 보장 (ADR-002).
        system: list[dict[str, Any]] = []
        for block in self.bundle.system_blocks:
            system.append({"text": block})
            system.append({"cachePoint": {"type": "default"}})
        return system

    def classify(self, masked_transcript: str) -> ClassificationResult:
        resp = self._client.converse(
            modelId=self.model_id,
            system=self._build_system(),  # type: ignore[arg-type]  # cachePoint not in stubs yet
            messages=[
                {
                    "role": "user",
                    "content": [{"text": self.bundle.build_user_message(masked_transcript)}],
                }
            ],
            inferenceConfig={"maxTokens": self.max_tokens},
        )
        text = resp["output"]["message"]["content"][0]["text"]
        return parse_and_validate(text, self.bundle.valid_codes)

    def warm(self) -> dict[str, int]:
        """프롬프트 캐시 워밍 (ADR-002): classify() 와 동일한 2-breakpoint system
        블록을 보내 같은 cache key 를 적중시킨다. 1토큰 user 메시지 + maxTokens=1,
        parse_and_validate 미수행 (워밍 핑은 유효한 분류 결과가 아님). EMF 용 Bedrock
        usage (cacheReadInputTokens 등) 반환. ADR-014: temperature 미전달.
        """
        resp = self._client.converse(
            modelId=self.model_id,
            system=self._build_system(),  # type: ignore[arg-type]  # cachePoint not in stubs yet
            messages=[{"role": "user", "content": [{"text": "warm"}]}],
            inferenceConfig={"maxTokens": 1},
        )
        # boto3 returns a TokenUsageTypeDef (TypedDict); normalize to a plain
        # dict[str, int] for EMF. 정수 변환 불가한 값은 스킵 (방어적).
        usage = resp.get("usage", {})
        out: dict[str, int] = {}
        for key, val in dict(usage).items():
            if isinstance(val, int):
                out[key] = val
        return out
