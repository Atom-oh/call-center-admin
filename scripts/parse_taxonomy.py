"""CLI: xlsx → src/prompts/v1.0/taxonomy_tree.json

NFD/NFC 파일명 호환:
xlsx 원본은 macOS 출처라 파일명이 NFD (한글 자모 분해형) 로 저장되어 있다.
사용자가 인라인으로 `상담어시스트_AWS전달자료.xlsx` 라고 타이핑하면 보통 NFC 로
들어와 직접 `open()` 시 FileNotFoundError. 본 CLI는:
  - `--xlsx` 인자가 정확히 존재하면 그대로 사용
  - 없으면 같은 디렉토리에서 NFD/NFC 모두 시도 + 동일 basename 의 .xlsx fallback
"""

from __future__ import annotations

import argparse
import sys
import unicodedata
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from lib.taxonomy import parse_xlsx, to_json, to_prompt_text


def _resolve_xlsx(path: Path) -> Path:
    if path.exists():
        return path
    parent = path.parent if path.parent != Path("") else Path(".")
    target = path.name
    for form in ("NFC", "NFD"):
        candidate = parent / unicodedata.normalize(form, target)
        if candidate.exists():
            return candidate
    # Final fallback: any .xlsx in the parent directory (e.g. CI checkout)
    for entry in parent.iterdir():
        if entry.suffix == ".xlsx":
            return entry
    raise FileNotFoundError(
        f"xlsx not found: {path} (tried NFC/NFD normalize + .xlsx fallback in {parent})"
    )


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--xlsx", type=Path, required=True)
    p.add_argument("--out-json", type=Path, default=Path("src/prompts/v1.0/taxonomy_tree.json"))
    p.add_argument("--out-md", type=Path, default=Path("src/prompts/v1.0/taxonomy_tree.md"))
    args = p.parse_args()

    resolved = _resolve_xlsx(args.xlsx)
    nodes = parse_xlsx(resolved)
    args.out_json.parent.mkdir(parents=True, exist_ok=True)
    args.out_json.write_text(to_json(nodes), encoding="utf-8")
    args.out_md.write_text(to_prompt_text(nodes), encoding="utf-8")
    print(f"parsed {len(nodes)} nodes from {resolved} → {args.out_json} + {args.out_md}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
