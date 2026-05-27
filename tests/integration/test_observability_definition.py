"""Observability 모듈 정적 정의 검증 (spec §6.2).

terraform apply 없이 main.tf / variables.tf / outputs.tf 텍스트를 직접 읽어
ADR Decision 들이 본 모듈에서 보존되었는지 검증한다. 한 Decision 이 깨지면
해당 test 가 즉시 fail — TDD 가드.

각 test 는 어떤 ADR 또는 spec 절을 보호하는지 docstring 으로 명시한다.
"""

from __future__ import annotations

from pathlib import Path

import pytest

MODULE_DIR = Path(__file__).parent.parent.parent / "infra/modules/observability"


@pytest.fixture(scope="module")
def main_tf() -> str:
    return (MODULE_DIR / "main.tf").read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def variables_tf() -> str:
    return (MODULE_DIR / "variables.tf").read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def outputs_tf() -> str:
    return (MODULE_DIR / "outputs.tf").read_text(encoding="utf-8")


# ──────────────────────────────────────────────────────────────────────────
# Spec §2.2 — 5 alarms required
# ──────────────────────────────────────────────────────────────────────────


def test_sns_alerts_topic_defined(main_tf: str) -> None:
    """spec §2.2: a single SNS topic fans out to all alarm subscribers."""
    assert 'resource "aws_sns_topic" "alerts"' in main_tf
    assert "callcenter-${var.env}-alerts" in main_tf


def test_five_required_alarms_defined(main_tf: str) -> None:
    """spec §2.2: exactly these 5 alarms must exist (sfn / classify-dlq / persist-dlq / bedrock / hitl)."""
    for alarm in (
        "sfn_failure",
        "classify_dlq_backlog",
        "persist_dlq_backlog",
        "bedrock_throttle",
        "hitl_backlog",
    ):
        assert f'resource "aws_cloudwatch_metric_alarm" "{alarm}"' in main_tf, (
            f"missing alarm: {alarm}"
        )


def test_all_alarms_route_to_sns(main_tf: str) -> None:
    """spec §2.2: every alarm fans to the single SNS topic."""
    routed = main_tf.count("alarm_actions = [aws_sns_topic.alerts.arn]")
    assert routed >= 5, f"expected >= 5 alarm_actions wirings, got {routed}"


def test_hitl_alarm_is_sustained_not_spike(main_tf: str) -> None:
    """spec §2.2 row 5: HITL backlog must trip only after 60min sustained breach."""
    block = main_tf.split('aws_cloudwatch_metric_alarm" "hitl_backlog"')[1].split(
        'aws_cloudwatch_metric_alarm" "'
    )[0]
    assert "evaluation_periods  = 12" in block, "HITL evaluation_periods must be 12"
    assert "datapoints_to_alarm = 12" in block, "HITL datapoints_to_alarm must be 12"


# ──────────────────────────────────────────────────────────────────────────
# Spec §2.3 — Dashboard 6 widgets
# ──────────────────────────────────────────────────────────────────────────


def test_dashboard_uses_callcenter_namespace(main_tf: str) -> None:
    """spec §2.1: all custom metrics live in 'callcenter/classification'."""
    assert 'resource "aws_cloudwatch_dashboard" "main"' in main_tf
    assert "callcenter/classification" in main_tf


def test_dashboard_includes_pii_per_type_widget(main_tf: str) -> None:
    """spec §2.3 widget 6: 4 PII types (phone / rrn / account / card) are charted."""
    assert "pii.maskApplied" in main_tf
    for pii_type in ("phone", "rrn", "account", "card"):
        assert f'"{pii_type}"' in main_tf, f"PII dashboard missing pii_type={pii_type}"


# ──────────────────────────────────────────────────────────────────────────
# ADR-005 — per-Lambda staging-dir packaging
# ──────────────────────────────────────────────────────────────────────────


def test_slack_relay_uses_inline_archive(main_tf: str) -> None:
    """ADR-005: Slack relay uses inline archive_file source (no shared staging-dir)."""
    assert 'data "archive_file" "slack_relay"' in main_tf
    # Inline source block is the marker — not source_dir referring to per-Lambda build.
    assert "source {" in main_tf
    assert 'filename = "handler.py"' in main_tf


def test_slack_relay_uses_urllib_only(main_tf: str) -> None:
    """ADR-005 corollary: inline Lambda has no deps installer — stdlib only."""
    assert "urllib.request" in main_tf
    assert "import requests" not in main_tf
    assert "from requests" not in main_tf


# ──────────────────────────────────────────────────────────────────────────
# ADR-006 — KMS data-class separation (Slack relay touches no encrypted data)
# ──────────────────────────────────────────────────────────────────────────


def test_slack_relay_iam_no_kms_grant(main_tf: str) -> None:
    """ADR-006: Slack relay handles plain Slack JSON, never KMS-encrypted data."""
    assert 'resource "aws_iam_role" "slack_relay"' in main_tf
    relay_section = main_tf.split('aws_iam_role" "slack_relay"')[1].split('resource "aws_')[0]
    assert "kms:" not in relay_section, "Slack relay IAM must not grant any KMS action"


def test_slack_relay_iam_log_group_scoped(main_tf: str) -> None:
    """ADR-006 corollary: log permissions scoped to the function's log group ARN, not '*'."""
    assert 'resource "aws_cloudwatch_log_group" "slack_relay"' in main_tf
    # The IAM policy should reference the specific log group, not Resource = "*".
    assert "aws_cloudwatch_log_group.slack_relay.arn" in main_tf
    relay_policy = main_tf.split('aws_iam_role_policy" "slack_relay"')
    if len(relay_policy) > 1:
        block = relay_policy[1].split("resource ")[0]
        # Strip HCL # comments so anti-example tokens inside docstrings don't trip
        # this guard. We only want to detect actual code-level Resource = "*".
        code_only = "\n".join(
            line for line in block.splitlines() if not line.lstrip().startswith("#")
        )
        assert 'Resource = "*"' not in code_only, "Slack relay IAM Resource '*' is forbidden"


# ──────────────────────────────────────────────────────────────────────────
# ADR-007 — SFN Express orchestration (alarm dim references state machine ARN)
# ──────────────────────────────────────────────────────────────────────────


def test_sfn_failure_alarm_uses_state_machine_arn_dim(main_tf: str) -> None:
    """ADR-007: sfn_failure alarm dims on StateMachineArn (per-state-machine isolation)."""
    block = main_tf.split('aws_cloudwatch_metric_alarm" "sfn_failure"')[1].split(
        'aws_cloudwatch_metric_alarm" "'
    )[0]
    assert "StateMachineArn = var.sfn_arn" in block


# ──────────────────────────────────────────────────────────────────────────
# ADR-009 — Atlantis / no inline secrets
# ──────────────────────────────────────────────────────────────────────────


def test_observability_does_not_create_secret(main_tf: str) -> None:
    """ADR-009: Slack webhook secret is sourced from Secrets Manager, not created here."""
    assert 'resource "aws_secretsmanager_secret"' not in main_tf
    assert 'resource "aws_secretsmanager_secret_version"' not in main_tf


# ──────────────────────────────────────────────────────────────────────────
# Decision-G1 — sensitive Slack webhook
# ──────────────────────────────────────────────────────────────────────────


def test_slack_webhook_variable_sensitive(variables_tf: str) -> None:
    """Decision-G1: webhook URL must be marked sensitive=true so plan output redacts it."""
    assert 'variable "slack_webhook_url"' in variables_tf
    block = variables_tf.split('variable "slack_webhook_url"')[1].split("variable ")[0]
    # Allow either canonical or aligned spacing.
    assert "sensitive   = true" in block or "sensitive = true" in block


# ──────────────────────────────────────────────────────────────────────────
# Spec §5 — outputs expose alarms/dashboard for smoke tests
# ──────────────────────────────────────────────────────────────────────────


def test_outputs_expose_alerts_topic_and_alarms(outputs_tf: str) -> None:
    """spec §5: outputs allow `aws cloudwatch describe-alarms` smoke verification."""
    assert 'output "alerts_topic_arn"' in outputs_tf
    assert 'output "alarm_names"' in outputs_tf
    assert 'output "dashboard_name"' in outputs_tf
