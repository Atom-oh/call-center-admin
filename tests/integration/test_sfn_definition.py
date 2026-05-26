"""SFN ASL JSON 정의 정적 검증 — apply 없이 구조만 확인."""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest


def _tf_show_json(env_dir: Path) -> dict | None:
    """terraform show -json 으로 plan 산출물 추출. terraform이 없거나 state가 비면 None."""
    if subprocess.run(["which", "terraform"], capture_output=True).returncode != 0:
        return None
    result = subprocess.run(
        ["terraform", f"-chdir={env_dir}", "show", "-json"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0 or not result.stdout.strip():
        return None
    return json.loads(result.stdout)


def test_sfn_definition_structure_extracted_from_module() -> None:
    """SFN ASL 정의를 모듈 소스에서 직접 읽어 구조 검증.

    terraform apply 없이 plan 산출물이 없을 때도 통과하도록 main.tf 텍스트를 본다.
    """
    tf_path = Path(__file__).parent.parent.parent / "infra/modules/classify-pipeline/main.tf"
    text = tf_path.read_text(encoding="utf-8")
    # Key states must be named in the definition
    for state in ("PiiGuard", "Classify", "ConfidenceBranch", "Verify", "Persist",
                  "MarkAutoHigh", "SendToClassifyDlq", "SendToPersistDlq"):
        assert state in text, f"missing SFN state: {state}"
    # EventBridge wiring
    assert "aws_cloudwatch_event_rule" in text
    assert "Object Created" in text
    assert "input_transformer" in text
