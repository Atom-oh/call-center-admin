"""Observability 모듈의 Terraform 정의 정적 검증.

terraform apply 없이 main.tf / variables.tf / outputs.tf 텍스트를 직접 읽어
필수 리소스 / 알람 / 대시보드 / Slack relay 구조가 깨지지 않았는지 확인한다.
PR9 회귀 가드 — 알람 하나를 실수로 삭제하면 CI 가 즉시 fail 한다.
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


def test_sns_alerts_topic_defined(main_tf: str) -> None:
    assert 'resource "aws_sns_topic" "alerts"' in main_tf
    assert "callcenter-${var.env}-alerts" in main_tf


def test_slack_relay_lambda_and_iam(main_tf: str) -> None:
    assert 'resource "aws_lambda_function" "slack_relay"' in main_tf
    assert 'resource "aws_iam_role" "slack_relay"' in main_tf
    # Log group must be a discrete resource (tight log scope, not Resource=*).
    assert 'resource "aws_cloudwatch_log_group" "slack_relay"' in main_tf
    # Subscription wires SNS topic to the Lambda.
    assert 'resource "aws_sns_topic_subscription" "slack"' in main_tf
    assert 'protocol  = "lambda"' in main_tf
    # SNS must be allowed to invoke the relay.
    assert 'resource "aws_lambda_permission" "sns_invoke"' in main_tf


def test_slack_relay_uses_urllib_not_requests(main_tf: str) -> None:
    """Inline Lambda must rely on stdlib only — no third-party dep would be installed
    in the zip (no requirements.txt for an archive_file inline source)."""
    assert "urllib.request" in main_tf
    assert "import requests" not in main_tf


def test_slack_webhook_variable_is_sensitive(variables_tf: str) -> None:
    assert 'variable "slack_webhook_url"' in variables_tf
    # The Slack webhook URL is a credential — sensitive=true ensures terraform plan
    # output redacts it.
    block = variables_tf.split('variable "slack_webhook_url"')[1].split("variable ")[0]
    assert "sensitive   = true" in block or "sensitive = true" in block


def test_five_required_alarms_defined(main_tf: str) -> None:
    """5 알람: sfn / classify dlq / persist dlq / bedrock throttle / hitl backlog."""
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
    """Every alarm must have alarm_actions wired to the alerts SNS topic."""
    occurrences = main_tf.count("alarm_actions = [aws_sns_topic.alerts.arn]")
    assert occurrences >= 5, (
        f"expected >= 5 alarm_actions wirings, got {occurrences} — one alarm not routed?"
    )


def test_hitl_alarm_is_sustained_not_spike(main_tf: str) -> None:
    """HITL backlog should require sustained breach (12 datapoints) to avoid noise."""
    block = main_tf.split('aws_cloudwatch_metric_alarm" "hitl_backlog"')[1].split(
        'aws_cloudwatch_metric_alarm" "'
    )[0]
    assert "evaluation_periods  = 12" in block
    assert "datapoints_to_alarm = 12" in block


def test_dashboard_defined_with_pii_widget(main_tf: str) -> None:
    """Dashboard must include a PII-per-type widget — visibility into Layer-1 hits."""
    assert 'resource "aws_cloudwatch_dashboard" "main"' in main_tf
    assert "pii.maskApplied" in main_tf
    # phone / rrn / account / card must all be referenced as dim values.
    for pii_type in ("phone", "rrn", "account", "card"):
        assert f'"{pii_type}"' in main_tf, f"PII dashboard missing pii_type={pii_type}"


def test_outputs_expose_alarm_names_for_smoke_tests(outputs_tf: str) -> None:
    """outputs.tf 로 alarm 목록을 노출 → smoke 스크립트가 list-metrics 로 검증 가능."""
    assert 'output "alerts_topic_arn"' in outputs_tf
    assert 'output "alarm_names"' in outputs_tf
    assert 'output "dashboard_name"' in outputs_tf
