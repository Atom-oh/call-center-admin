"""Prompt bundle builder 테스트."""
from pathlib import Path

from lib.prompts import PromptBundle, build_prompt_bundle


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
    bundle = PromptBundle(
        system_blocks=["rules", "tree"], valid_codes={"x"}, prompt_version="v1.0"
    )
    user = bundle.build_user_message(masked_transcript="agent: hi")
    assert "agent: hi" in user
    assert "JSON" in user
