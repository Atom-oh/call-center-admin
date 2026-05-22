"""xlsx 분류체계 파서 + 트리 직렬화.

xlsx 컬럼 구조 (1-indexed):
  B: 유형1 (대분류 이름)
  C: 유형2 (중분류 이름)
  D: 유형3 (소분류 이름)
  E: 유형 코드
  F: 내용 (사용 안 함)
  G: v4 description (LLM 프롬프트에 사용)
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterator

import openpyxl


@dataclass
class TaxonomyNode:
    name: str
    code: str | None
    description: str
    level: int  # 1=대, 2=중, 3=소
    parent_code: str | None = None
    children: list[TaxonomyNode] = field(default_factory=list)

    def effective_description(self) -> str:
        """비어 있으면 가장 가까운 조상의 description 반환."""
        if self.description:
            return self.description
        return getattr(self, "_inherited_description", "")


def parse_xlsx(path: Path) -> list[TaxonomyNode]:
    """xlsx를 평면 노드 리스트로 파싱 (DFS 순서)."""
    wb = openpyxl.load_workbook(str(path), data_only=True)
    ws = wb["상담유형 추천_유형 및 디스크립션"]
    nodes: list[TaxonomyNode] = []
    current_l1: TaxonomyNode | None = None
    current_l2: TaxonomyNode | None = None

    # row 3부터 실제 데이터 시작 (row 1-2는 헤더)
    for row in ws.iter_rows(min_row=3, max_col=8, values_only=True):
        _, y1, y2, y3, code, _content, desc, _glyphs = row
        desc_str = (desc or "").strip() if desc else ""

        if y1:
            node = TaxonomyNode(name=y1.strip(), code=code, description=desc_str, level=1)
            current_l1 = node
            current_l2 = None
            nodes.append(node)
        elif y2:
            assert current_l1 is not None, "중분류 before any 대분류"
            node = TaxonomyNode(
                name=y2.strip(),
                code=code,
                description=desc_str,
                level=2,
                parent_code=current_l1.code,
            )
            node._inherited_description = current_l1.description  # type: ignore[attr-defined]
            current_l1.children.append(node)
            current_l2 = node
            nodes.append(node)
        elif y3:
            assert current_l2 is not None, "소분류 before any 중분류"
            node = TaxonomyNode(
                name=y3.strip(),
                code=code,
                description=desc_str,
                level=3,
                parent_code=current_l2.code,
            )
            node._inherited_description = (  # type: ignore[attr-defined]
                current_l2.description or current_l1.description if current_l1 else ""
            )
            current_l2.children.append(node)
            nodes.append(node)

    return nodes


def iter_tree(nodes: list[TaxonomyNode]) -> Iterator[TaxonomyNode]:
    """DFS 순회 (대 → 중 → 소)."""
    for n in nodes:
        if n.level == 1:
            yield n
            for m in n.children:
                yield m
                yield from m.children


def to_prompt_text(nodes: list[TaxonomyNode]) -> str:
    """LLM 프롬프트용 markdown 직렬화."""
    lines: list[str] = []
    for n in nodes:
        if n.level == 1:
            lines.append(f"## [대분류] {n.name} — code: {n.code}")
            if n.description:
                lines.append(f"설명: {n.description}")
            lines.append("")
        elif n.level == 2:
            lines.append(f"  ### [중분류] {n.name} — code: {n.code}")
            if n.description:
                lines.append(f"  설명: {n.description}")
            lines.append("")
        elif n.level == 3:
            lines.append(f"    #### [소분류] {n.name} — code: {n.code}")
            if n.description:
                lines.append(f"    설명: {n.description}")
            lines.append("")
    return "\n".join(lines)


def to_json(nodes: list[TaxonomyNode]) -> str:
    def encode(n: TaxonomyNode) -> dict:
        return {
            "name": n.name,
            "code": n.code,
            "description": n.description,
            "level": n.level,
            "parent_code": n.parent_code,
            "children_codes": [c.code for c in n.children],
        }

    return json.dumps([encode(n) for n in nodes], ensure_ascii=False, indent=2)
