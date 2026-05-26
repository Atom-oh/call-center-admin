"""CLI: xlsx → src/prompts/v1.0/taxonomy_tree.json"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from lib.taxonomy import parse_xlsx, to_json, to_prompt_text


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--xlsx", type=Path, required=True)
    p.add_argument("--out-json", type=Path, default=Path("src/prompts/v1.0/taxonomy_tree.json"))
    p.add_argument("--out-md", type=Path, default=Path("src/prompts/v1.0/taxonomy_tree.md"))
    args = p.parse_args()

    nodes = parse_xlsx(args.xlsx)
    args.out_json.parent.mkdir(parents=True, exist_ok=True)
    args.out_json.write_text(to_json(nodes), encoding="utf-8")
    args.out_md.write_text(to_prompt_text(nodes), encoding="utf-8")
    print(f"parsed {len(nodes)} nodes → {args.out_json} + {args.out_md}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
