"""4종 운영 런북 + E2E smoke 스크립트 정의 검증 (spec §6.2)."""

from __future__ import annotations

from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent.parent
RUNBOOKS_DIR = REPO_ROOT / "docs" / "runbooks"
REQUIRED_RUNBOOKS = (
    "bedrock-throttling.md",
    "hitl-backlog.md",
    "prompt-rollback.md",
    "pii-mask-failure.md",
)
REQUIRED_SECTIONS = ("증상", "진단", "즉시 대응", "영구 해결")
ALARM_REFERENCES = {
    "bedrock-throttling.md": "callcenter-${env}-bedrock-throttle",
    "hitl-backlog.md": "callcenter-${env}-hitl-backlog",
}


@pytest.mark.parametrize("filename", REQUIRED_RUNBOOKS)
def test_runbook_exists(filename: str) -> None:
    """spec §3: 4 runbooks must all exist."""
    assert (RUNBOOKS_DIR / filename).exists(), f"missing runbook: docs/runbooks/{filename}"


@pytest.mark.parametrize("filename", REQUIRED_RUNBOOKS)
def test_runbook_has_required_sections(filename: str) -> None:
    """spec §3: every runbook must include 증상 / 진단 / 즉시 대응 / 영구 해결."""
    text = (RUNBOOKS_DIR / filename).read_text(encoding="utf-8")
    for section in REQUIRED_SECTIONS:
        assert section in text, f"runbook {filename!r} missing section: {section!r}"


def test_alarm_runbooks_reference_alarm_names() -> None:
    """spec §3: alarm-driven runbooks must reference their alarm name so an oncall
    engineer can match the Slack message body to the right runbook."""
    for filename, alarm_template in ALARM_REFERENCES.items():
        text = (RUNBOOKS_DIR / filename).read_text(encoding="utf-8")
        # Allow ${env} or {env} placeholder forms.
        assert alarm_template in text or alarm_template.replace("${env}", "{env}") in text, (
            f"runbook {filename!r} does not reference alarm {alarm_template!r}"
        )


def test_e2e_smoke_script_exists_with_env_arg() -> None:
    """spec §5: scripts/e2e_smoke.py must exist with --env flag for dev/stg/prd."""
    path = REPO_ROOT / "scripts" / "e2e_smoke.py"
    assert path.exists(), "scripts/e2e_smoke.py is required"
    text = path.read_text(encoding="utf-8")
    assert "--env" in text, "e2e_smoke must accept --env CLI argument"
    # The script must define a main() entrypoint or be invocable via __main__.
    assert "def main" in text or "if __name__" in text, "e2e_smoke.py must define an entrypoint"
