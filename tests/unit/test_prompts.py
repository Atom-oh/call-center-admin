"""Prompt bundle builder 테스트."""

import json
from pathlib import Path

import pytest

from lib.prompts import PromptBundle, _serialize_taxonomy, build_prompt_bundle


def test_build_prompt_bundle_has_two_cache_breakpoints(repo_root: Path) -> None:
    rules = (repo_root / "src/prompts/v1.0/system_rules.md").read_text(encoding="utf-8")
    tree_json = (repo_root / "src/prompts/v1.0/taxonomy_tree.json").read_text(encoding="utf-8")
    bundle = build_prompt_bundle(rules_md=rules, taxonomy_json=tree_json)
    assert isinstance(bundle, PromptBundle)
    assert len(bundle.system_blocks) == 2
    assert bundle.valid_codes
    # 룰 블록은 R5 PII 룰을 반드시 포함
    assert "R5" in bundle.system_blocks[0]
    # 트리 블록은 18개 대분류 표시 포함
    assert bundle.system_blocks[1].count("[대분류]") == 18


def test_user_message_includes_transcript() -> None:
    bundle = PromptBundle(system_blocks=["rules", "tree"], valid_codes={"x"}, prompt_version="v1.0")
    user = bundle.build_user_message(masked_transcript="agent: hi")
    assert "agent: hi" in user
    assert "JSON" in user


def test_taxonomy_with_invalid_level_raises_value_error() -> None:
    """taxonomy_tree.json이 손상되어 level=0 또는 level=4 노드가 들어와도
    silent wrap (level=0 → marker[-1]="소분류") 대신 ValueError로 surface해야 한다.
    """
    bad = json.dumps(
        [{"name": "x", "code": "X", "description": "", "level": 4, "parent_code": None}]
    )
    with pytest.raises(ValueError, match="invalid level 4"):
        _serialize_taxonomy(bad)


def test_bundle_valid_codes_has_expected_count(repo_root: Path) -> None:
    """v1.0 taxonomy에서 code가 있는 노드는 184개. 회귀 방지용."""
    tree_json = (repo_root / "src/prompts/v1.0/taxonomy_tree.json").read_text(encoding="utf-8")
    nodes = json.loads(tree_json)
    expected = sum(1 for n in nodes if n["code"])
    bundle = build_prompt_bundle(rules_md="x", taxonomy_json=tree_json)
    assert len(bundle.valid_codes) == expected
