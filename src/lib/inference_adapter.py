"""Phase 3에서 ML 모델 교체 가능하도록 한 어댑터 추상."""
from __future__ import annotations

from typing import Protocol

from lib.output_schema import ClassificationResult


class InferenceAdapter(Protocol):
    name: str
    version: str

    def classify(self, masked_transcript: str) -> ClassificationResult: ...
