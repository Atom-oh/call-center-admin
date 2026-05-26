"""골든셋에 대해 현재 프롬프트 버전 평가."""
from __future__ import annotations

import argparse
import csv
import json
import sys
from datetime import UTC, datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from lib.bedrock_client import BedrockAdapter
from lib.prompts import build_prompt_bundle


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--golden", type=Path, default=Path("tests/golden/samples.json"))
    p.add_argument("--prompt-dir", type=Path, default=Path("src/prompts/v1.0"))
    p.add_argument("--model-id", default="anthropic.claude-opus-4-7-20260101-v1:0")
    p.add_argument("--history", type=Path, default=Path("tests/golden/eval-history.csv"))
    p.add_argument("--skip-tbd", action="store_true", help="placeholder 행은 건너뛴다")
    args = p.parse_args()

    samples = json.loads(args.golden.read_text(encoding="utf-8"))
    if args.skip_tbd:
        samples = [s for s in samples if s["expected"]["대code"] != "TBD"]
    if not samples:
        print("no labeled samples; nothing to evaluate")
        return 0

    rules = (args.prompt_dir / "system_rules.md").read_text(encoding="utf-8")
    tree = (args.prompt_dir / "taxonomy_tree.json").read_text(encoding="utf-8")
    adapter = BedrockAdapter(args.model_id, build_prompt_bundle(rules, tree))

    correct = {"대": 0, "중": 0, "소": 0}
    total = len(samples)
    for s in samples:
        try:
            r = adapter.classify(s["transcript"])
        except Exception as ex:
            print(f"[FAIL] {s['id']}: {ex}")
            continue
        exp = s["expected"]
        if r.대.code == exp["대code"]:
            correct["대"] += 1
        if r.중.code == exp["중code"]:
            correct["중"] += 1
        if r.소.code == exp["소code"]:
            correct["소"] += 1

    acc = {k: v / total for k, v in correct.items()}
    print(f"accuracy: 대={acc['대']:.2%} 중={acc['중']:.2%} 소={acc['소']:.2%} (n={total})")

    args.history.parent.mkdir(parents=True, exist_ok=True)
    write_header = not args.history.exists()
    with args.history.open("a", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        if write_header:
            w.writerow(["timestamp", "prompt_version", "model_id", "n", "acc_대", "acc_중", "acc_소"])
        w.writerow([
            datetime.now(UTC).isoformat(),
            "v1.0",
            args.model_id,
            total,
            acc["대"],
            acc["중"],
            acc["소"],
        ])

    if acc["대"] < 0.80:
        print(f"FAIL: 대 accuracy {acc['대']:.2%} < 80%")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
