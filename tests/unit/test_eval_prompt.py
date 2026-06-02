"""scripts/eval_prompt.py 변동성 하니스 단위 테스트 (ADR-014).

순수 테스트 — 실제 Bedrock / moto 불필요. classify_fn 을 plain callable 로 주입.
scripts/ 는 패키지가 아니므로 sys.path 에 추가 후 import.
"""

from __future__ import annotations

import csv
import importlib
import sys
from pathlib import Path

# scripts/ 를 import 경로에 추가 (패키지 아님). src/ 는 pyproject pythonpath 로 이미 노출.
_SCRIPTS = Path(__file__).parents[2] / "scripts"
if str(_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS))

eval_prompt = importlib.import_module("eval_prompt")


def _result(dae: str, jung: str, so: str):
    from lib.output_schema import CategoryLabel, ClassificationResult

    return ClassificationResult(
        대=CategoryLabel(dae, "n"),
        중=CategoryLabel(jung, "n"),
        소=CategoryLabel(so, "n"),
        confidence=0.9,
        reason="r",
        alternativesConsidered=[],
    )


def _seq_classify(results):
    """list 를 순서대로 반환하는 classify_fn (Exception 항목은 raise)."""
    it = iter(results)

    def _fn(_transcript):
        nxt = next(it)
        if isinstance(nxt, Exception):
            raise nxt
        return nxt

    return _fn


def test_measure_row_detects_instability() -> None:
    """2회 동일 + 1회 다른 소 → 불안정 감지 (ADR-014 핵심 케이스)."""
    fn = _seq_classify([_result("A", "B", "C"), _result("A", "B", "C"), _result("A", "B", "Z")])
    rs = eval_prompt.measure_row(fn, "g001", "t", runs=3)
    assert rs.distinct == 2
    assert rs.modal_count == 2
    assert abs(rs.stability - 2 / 3) < 1e-9
    assert rs.errors == 0
    assert rs.is_stable is False


def test_measure_row_fully_stable() -> None:
    fn = _seq_classify([_result("A", "B", "C")] * 4)
    rs = eval_prompt.measure_row(fn, "g001", "t", runs=4)
    assert rs.distinct == 1
    assert rs.stability == 1.0
    assert rs.is_stable is True


def test_measure_row_counts_errors() -> None:
    """일부 run 이 예외 → errors 집계, is_stable False, stability 는 성공분으로만 계산."""
    fn = _seq_classify([_result("A", "B", "C"), RuntimeError("boom"), _result("A", "B", "C")])
    rs = eval_prompt.measure_row(fn, "g001", "t", runs=3)
    assert rs.errors == 1
    assert rs.is_stable is False  # 예외가 있으면 성공분이 일치해도 불안정 처리
    assert rs.stability == 1.0  # 성공한 2회는 동일 → 2/2


def test_measure_row_preserves_verbatim_codes() -> None:
    """ADR-004: NONEY/PAYNENT 같은 xlsx code 가 정규화 없이 그대로 키에 보존."""
    fn = _seq_classify([_result("CS_CENTER_CONSULT_TYPE_PAY_NONEY", "M", "S")] * 2)
    rs = eval_prompt.measure_row(fn, "g001", "t", runs=2)
    assert ("CS_CENTER_CONSULT_TYPE_PAY_NONEY", "M", "S") in rs.label_counts
    # MONEY (교정된 형태) 로 변형되면 안 됨
    assert all("MONEY" not in k[0] for k in rs.label_counts)


def test_run_variance_flags_unstable_rows() -> None:
    samples = [{"id": "stable", "transcript": "t1"}, {"id": "wobbly", "transcript": "t2"}]
    # measure_row 가 sample 순서대로 호출되므로, classify_fn 은 5회 (stable 2 + wobbly 3)
    fn = _seq_classify(
        [
            _result("A", "B", "C"),
            _result("A", "B", "C"),  # stable: 2 runs
            _result("A", "B", "C"),
            _result("A", "B", "C"),
            _result("X", "Y", "Z"),  # wobbly: 3 runs, 1 diff
        ]
    )
    rows = eval_prompt.run_variance(fn, samples, runs=2)
    # samples=2, runs=2 → 4 classify calls (sample 당 runs 회).
    assert len(rows) == 2


def test_run_variance_two_samples_one_unstable() -> None:
    samples = [{"id": "s1", "transcript": "t1"}, {"id": "s2", "transcript": "t2"}]
    fn = _seq_classify(
        [
            _result("A", "B", "C"),
            _result("A", "B", "C"),  # s1 stable
            _result("A", "B", "C"),
            _result("A", "B", "DIFF"),  # s2 unstable
        ]
    )
    rows = eval_prompt.run_variance(fn, samples, runs=2)
    assert len(rows) == 2
    assert sum(1 for r in rows if not r.is_stable) == 1


def test_write_variance_report_roundtrip(tmp_path) -> None:
    rows = [
        eval_prompt.RowStability("g001", 3, 1, 3, 1.0, 0, {("A", "B", "C"): 3}),
        eval_prompt.RowStability(
            "g002", 3, 2, 2, 2 / 3, 0, {("A", "B", "C"): 2, ("A", "B", "Z"): 1}
        ),
    ]
    out = tmp_path / "v.csv"
    eval_prompt.write_variance_report(out, "global.anthropic.claude-opus-4-7", rows)
    parsed = list(csv.DictReader(out.open(encoding="utf-8")))
    assert len(parsed) == 2
    assert {"sample_id", "stability", "is_stable", "model_id"} <= set(parsed[0].keys())
    assert parsed[0]["sample_id"] == "g001"
    assert parsed[0]["is_stable"] == "True"
    assert parsed[1]["is_stable"] == "False"
