"""Taxonomy parser and tree serialization tests."""
import json
from pathlib import Path

import pytest

from lib.taxonomy import TaxonomyNode, parse_xlsx, to_json, to_prompt_text


def test_parse_xlsx_returns_18_top_level_nodes(xlsx_path: Path) -> None:
    tree = parse_xlsx(xlsx_path)
    top_level = [n for n in tree if n.level == 1]
    assert len(top_level) == 18, f"expected 18 대분류, got {len(top_level)}"


def test_parse_xlsx_returns_64_mid_level_nodes(xlsx_path: Path) -> None:
    tree = parse_xlsx(xlsx_path)
    mid = [n for n in tree if n.level == 2]
    assert len(mid) == 64, f"expected 64 중분류, got {len(mid)}"


def test_parse_xlsx_returns_131_leaf_nodes(xlsx_path: Path) -> None:
    tree = parse_xlsx(xlsx_path)
    leaves = [n for n in tree if n.level == 3]
    assert len(leaves) == 131, f"expected 131 소분류, got {len(leaves)}"


def test_node_has_code_and_name(xlsx_path: Path) -> None:
    tree = parse_xlsx(xlsx_path)
    paymoney = next(n for n in tree if n.name == "페이머니")
    assert paymoney.code == "CS_CENTER_CONSULT_TYPE_PAY_NONEY"
    assert paymoney.level == 1
    assert paymoney.description is not None
    assert len(paymoney.description) > 0


def test_mid_node_inherits_parent_description_when_empty(xlsx_path: Path) -> None:
    tree = parse_xlsx(xlsx_path)
    chg = next(n for n in tree if n.name == "충전/출금" and n.level == 2)
    assert chg.parent_code == "CS_CENTER_CONSULT_TYPE_PAY_NONEY"
    # 중분류 description이 비어 있어도 effective_description은 부모 상속
    assert chg.effective_description() != ""


def test_to_json_roundtrip(xlsx_path: Path) -> None:
    tree = parse_xlsx(xlsx_path)
    payload = json.loads(to_json(tree))
    assert len(payload) == 213, f"expected 213 entries, got {len(payload)}"
    counts = {1: 0, 2: 0, 3: 0}
    for entry in payload:
        counts[entry["level"]] += 1
    assert counts == {1: 18, 2: 64, 3: 131}, f"unexpected level counts: {counts}"


def test_to_prompt_text_has_all_markers(xlsx_path: Path) -> None:
    tree = parse_xlsx(xlsx_path)
    text = to_prompt_text(tree)
    assert text.count("[대분류]") == 18
    assert text.count("[중분류]") == 64
    assert text.count("[소분류]") == 131


def test_to_prompt_text_omits_none_code(xlsx_path: Path) -> None:
    tree = parse_xlsx(xlsx_path)
    text = to_prompt_text(tree)
    assert "code: None" not in text, (
        "rendered markdown must not contain literal 'code: None' "
        "(would pollute LLM prompt and cause spurious 'None' classifications)"
    )
