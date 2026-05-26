"""Bedrock Converse 프롬프트 빌더 + 캐시 브레이크포인트."""

from __future__ import annotations

import json
from dataclasses import dataclass

PROMPT_VERSION = "v1.0"


@dataclass
class PromptBundle:
    system_blocks: list[str]
    valid_codes: set[str]
    prompt_version: str

    def build_user_message(self, masked_transcript: str) -> str:
        return (
            "다음은 콜센터 상담 STT(개인정보가 마스킹됨)이다. "
            "이 대화를 분류 체계의 대/중/소 코드로 분류하라. "
            "출력은 JSON 한 객체만 (마크다운 코드블록 금지).\n\n"
            "---\n"
            f"{masked_transcript}\n"
            "---\n"
        )


def _serialize_taxonomy(taxonomy_json: str) -> tuple[str, set[str]]:
    nodes = json.loads(taxonomy_json)
    lines: list[str] = []
    codes: set[str] = set()
    for n in nodes:
        # Guard against taxonomy malformation — PR1 currently emits only 1/2/3
        # but a future taxonomy change shouldn't crash with IndexError or silently
        # wrap to the last marker via negative indexing.
        if not 1 <= n["level"] <= 3:
            raise ValueError(f"invalid level {n['level']} for node {n.get('code')}")
        if n["code"]:
            codes.add(n["code"])
        marker_idx = n["level"] - 1
        marker = ["대분류", "중분류", "소분류"][marker_idx]
        header_prefix = ["##", "###", "####"][marker_idx]
        indent = "  " * marker_idx
        code_suffix = f" — code: {n['code']}" if n["code"] else ""
        lines.append(f"{indent}{header_prefix} [{marker}] {n['name']}{code_suffix}")
        # PR1 fix: use effective_description (parent-inherited) when raw is empty
        desc = n.get("effective_description") or n.get("description") or ""
        if desc:
            lines.append(f"{indent}설명: {desc}")
        lines.append("")
    return "\n".join(lines), codes


def build_prompt_bundle(rules_md: str, taxonomy_json: str) -> PromptBundle:
    tree_block, codes = _serialize_taxonomy(taxonomy_json)
    return PromptBundle(
        system_blocks=[rules_md, tree_block],
        valid_codes=codes,
        prompt_version=PROMPT_VERSION,
    )
