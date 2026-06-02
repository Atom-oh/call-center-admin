"""골든셋에 대해 현재 프롬프트 버전 평가 + (ADR-014) 라벨 변동성 측정."""

from __future__ import annotations

import argparse
import csv
import json
import sys
from collections import Counter
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from lib.bedrock_client import BedrockAdapter
from lib.output_schema import ClassificationResult
from lib.prompts import build_prompt_bundle

_UTC = timezone.utc  # noqa: UP017


# ──────────────────────────────────────────────────────────────────────────
# ADR-014: 라벨 변동성 측정 (temperature 제거 후 결정성 검증) — pure, testable
# ──────────────────────────────────────────────────────────────────────────


@dataclass
class RowStability:
    sample_id: str
    runs: int
    distinct: int  # 관측된 (대,중,소) 튜플 종류 수
    modal_count: int  # 최빈 튜플의 등장 횟수
    stability: float  # modal_count / 성공 호출 수 (1.0 = 완전 결정적)
    errors: int  # classify() 예외 횟수
    label_counts: dict[tuple[str, str, str], int]

    @property
    def is_stable(self) -> bool:
        return self.errors == 0 and self.distinct == 1


def measure_row(
    classify_fn: Callable[[str], ClassificationResult],
    sample_id: str,
    transcript: str,
    runs: int,
) -> RowStability:
    """transcript 를 runs 회 분류, (대,중,소) 코드 튜플 분포로 안정성 계산.

    코드 문자열은 ADR-004 에 따라 verbatim 비교 (NONEY/PAYNENT 정규화 금지).
    한 호출 실패가 측정 전체를 깨면 안 되므로 예외는 errors 로 집계.
    """
    counts: Counter[tuple[str, str, str]] = Counter()
    errors = 0
    for _ in range(runs):
        try:
            r = classify_fn(transcript)
        except Exception as ex:
            errors += 1
            print(f"  [run-fail] {sample_id}: {ex}")
            continue
        counts[(r.대.code, r.중.code, r.소.code)] += 1
    modal_count = max(counts.values(), default=0)
    successful = sum(counts.values())
    return RowStability(
        sample_id=sample_id,
        runs=runs,
        distinct=len(counts),
        modal_count=modal_count,
        stability=(modal_count / successful) if successful else 0.0,
        errors=errors,
        label_counts=dict(counts),
    )


def run_variance(
    classify_fn: Callable[[str], ClassificationResult],
    samples: list,
    runs: int,
) -> list[RowStability]:
    rows = [measure_row(classify_fn, s["id"], s["transcript"], runs) for s in samples]
    unstable = [r for r in rows if not r.is_stable]
    print(f"\nvariance: runs={runs} rows={len(rows)} unstable={len(unstable)}")
    for r in rows:
        flag = "" if r.is_stable else "  <-- UNSTABLE"
        print(
            f"  {r.sample_id}: stability={r.stability:.0%} "
            f"distinct={r.distinct} errors={r.errors}{flag}"
        )
    return rows


def write_variance_report(path: Path, model_id: str, rows: list[RowStability]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    write_header = not path.exists()
    ts = datetime.now(_UTC).isoformat()
    with path.open("a", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        if write_header:
            w.writerow(
                [
                    "timestamp",
                    "model_id",
                    "sample_id",
                    "runs",
                    "distinct_labels",
                    "modal_count",
                    "stability",
                    "errors",
                    "is_stable",
                ]
            )
        for r in rows:
            w.writerow(
                [
                    ts,
                    model_id,
                    r.sample_id,
                    r.runs,
                    r.distinct,
                    r.modal_count,
                    f"{r.stability:.4f}",
                    r.errors,
                    r.is_stable,
                ]
            )


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--golden", type=Path, default=Path("tests/golden/samples.json"))
    p.add_argument("--prompt-dir", type=Path, default=Path("src/prompts/v1.0"))
    p.add_argument("--model-id", default="global.anthropic.claude-opus-4-7")
    p.add_argument("--history", type=Path, default=Path("tests/golden/eval-history.csv"))
    p.add_argument("--skip-tbd", action="store_true", help="placeholder 행은 건너뛴다")
    p.add_argument(
        "--runs",
        type=int,
        default=1,
        help="각 골든셋 행을 N회 분류 호출하여 (대,중,소) 라벨 안정성 측정 (ADR-014 변동성). "
        "N=1 이면 기존 정확도 평가만 수행.",
    )
    p.add_argument(
        "--variance-report",
        type=Path,
        default=Path("tests/golden/variance-report.csv"),
        help="--runs>1 일 때 per-row 안정성 결과를 기록할 CSV 경로.",
    )
    args = p.parse_args()

    if args.runs < 1:
        print("--runs must be >= 1")
        return 2

    samples = json.loads(args.golden.read_text(encoding="utf-8"))
    if args.skip_tbd:
        samples = [s for s in samples if s["expected"]["대code"] != "TBD"]
    if not samples:
        print("no labeled samples; nothing to evaluate")
        return 0

    rules = (args.prompt_dir / "system_rules.md").read_text(encoding="utf-8")
    tree = (args.prompt_dir / "taxonomy_tree.json").read_text(encoding="utf-8")
    adapter = BedrockAdapter(args.model_id, build_prompt_bundle(rules, tree))

    # ADR-014: 변동성 모드 — 각 행 N회 호출하여 라벨 안정성 측정 (별도 리포트,
    # eval-history.csv 의 정확도 schema/CI 게이트 미접촉). early-return.
    if args.runs > 1:
        rows = run_variance(adapter.classify, samples, args.runs)
        write_variance_report(args.variance_report, args.model_id, rows)
        unstable = [r for r in rows if not r.is_stable]
        if unstable:
            print(f"FAIL: {len(unstable)} row(s) showed label variance across {args.runs} runs")
            return 1
        return 0

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
            w.writerow(
                ["timestamp", "prompt_version", "model_id", "n", "acc_대", "acc_중", "acc_소"]
            )
        w.writerow(
            [
                datetime.now(_UTC).isoformat(),
                "v1.0",
                args.model_id,
                total,
                acc["대"],
                acc["중"],
                acc["소"],
            ]
        )

    if acc["대"] < 0.80:
        print(f"FAIL: 대 accuracy {acc['대']:.2%} < 80%")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
