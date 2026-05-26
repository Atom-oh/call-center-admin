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

import openpyxl


@dataclass
class TaxonomyNode:
    name: str
    code: str | None
    description: str
    level: int  # 1=대, 2=중, 3=소
    parent_code: str | None = None
    inherited_description: str = ""
    children: list[TaxonomyNode] = field(default_factory=list)

    def effective_description(self) -> str:
        """비어 있으면 가장 가까운 조상의 description 반환."""
        if self.description:
            return self.description
        return self.inherited_description


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
                inherited_description=current_l1.description,
            )
            current_l1.children.append(node)
            current_l2 = node
            nodes.append(node)
        elif y3:
            assert current_l2 is not None, "소분류 before any 중분류"
            inherited = current_l2.description or (current_l1.description if current_l1 else "")
            node = TaxonomyNode(
                name=y3.strip(),
                code=code,
                description=desc_str,
                level=3,
                parent_code=current_l2.code,
                inherited_description=inherited,
            )
            current_l2.children.append(node)
            nodes.append(node)

    return nodes


def to_prompt_text(nodes: list[TaxonomyNode]) -> str:
    """LLM 프롬프트용 markdown 직렬화.

    - description이 비어 있는 중/소분류는 부모의 description을 상속.
    - code가 None인 노드는 ` — code: ...` 접미사를 생략 (LLM이 "None"을 분류값으로 출력하는 것을 방지).
    """
    lines: list[str] = []
    for n in nodes:
        code_suffix = f" — code: {n.code}" if n.code is not None else ""
        desc = n.effective_description()
        if n.level == 1:
            lines.append(f"## [대분류] {n.name}{code_suffix}")
            if desc:
                lines.append(f"설명: {desc}")
            lines.append("")
        elif n.level == 2:
            lines.append(f"  ### [중분류] {n.name}{code_suffix}")
            if desc:
                lines.append(f"  설명: {desc}")
            lines.append("")
        elif n.level == 3:
            lines.append(f"    #### [소분류] {n.name}{code_suffix}")
            if desc:
                lines.append(f"    설명: {desc}")
            lines.append("")
    return "\n".join(lines)


def to_json(nodes: list[TaxonomyNode]) -> str:
    """트리 JSON 직렬화.

    - `description`: xlsx 원본 값 (비어 있을 수 있음)
    - `effective_description`: 부모 상속까지 적용한 최종 값 (LLM 프롬프트와 동일)
    - `children_codes`: code가 None인 자식은 제외하여 다운스트림이 None을 다룰 필요 없도록 함
    """

    def encode(n: TaxonomyNode) -> dict:
        return {
            "name": n.name,
            "code": n.code,
            "description": n.description,
            "effective_description": n.effective_description(),
            "level": n.level,
            "parent_code": n.parent_code,
            "children_codes": [c.code for c in n.children if c.code is not None],
        }

    return json.dumps([encode(n) for n in nodes], ensure_ascii=False, indent=2)
