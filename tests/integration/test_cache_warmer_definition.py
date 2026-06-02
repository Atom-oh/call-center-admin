"""cache_warmer (ADR-002) Terraform 정의 정적 검증.

terraform apply 없이 classify-pipeline 모듈의 main.tf / variables.tf / outputs.tf
텍스트를 읽어 ADR-002 (prompt cache warming) 의 결정들이 보존되었는지 검증한다:

- OPTIONAL / default-OFF (모든 aws_* 리소스가 var.enable_cache_warming 으로 count-gate)
- classify 와 동일 MODEL_ID + prompts staging (같은 cache key)
- IAM 최소권한 (bedrock:InvokeModel + logs 만, KMS/S3/DDB 없음 — ADR-006)
- EventBridge cron schedule 이 변수로 주입

각 test 는 어떤 ADR 결정을 보호하는지 docstring 으로 명시한다.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

MODULE_DIR = Path(__file__).parent.parent.parent / "infra/modules/classify-pipeline"
DEV_DIR = Path(__file__).parent.parent.parent / "infra/envs/dev"


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
# ADR-002 — OPTIONAL / default-OFF
# ──────────────────────────────────────────────────────────────────────────


def test_enable_flag_defaults_off(variables_tf: str) -> None:
    """ADR-002: enable_cache_warming bool, default false (zero-cost when off)."""
    block = variables_tf[variables_tf.index('variable "enable_cache_warming"') :]
    head = block[: block.index("}") + 1]
    assert "type    = bool" in head or "type        = bool" in head
    assert "default = false" in head or "default     = false" in head


def test_all_aws_resources_count_gated(main_tf: str) -> None:
    """ADR-002: 모든 aws_* cache-warmer 리소스가 count = var.enable_cache_warming ? 1 : 0.

    data.external / data.archive_file 은 AWS 리소스를 만들지 않으므로 (zip 빌드만)
    gate 대상이 아니다 — aws_ 로 시작하는 cache_warmer/cache_warm 리소스만 검사.
    """
    # cache-warmer 섹션만 추출 (ADR-002 주석 마커 이후)
    section = main_tf[main_tf.index("ADR-002: OPTIONAL cache-warming") :]
    aws_blocks = re.findall(r'resource "(aws_[\w]+)" "(cache_warm\w*)" \{', section)
    assert aws_blocks, "expected cache-warmer aws_* resources"
    for _type, name in aws_blocks:
        # 각 블록 본문에서 count gate 확인
        start = section.index(f'"{name}" {{')
        body = section[start : start + 400]
        assert "count" in body and "var.enable_cache_warming ? 1 : 0" in body, (
            f"{_type}.{name} not count-gated on enable_cache_warming"
        )


def test_expected_resource_set(main_tf: str) -> None:
    """ADR-002: 워밍에 필요한 7종 aws_* 리소스 + 2종 data 소스가 모두 정의."""
    for needed in (
        'resource "aws_iam_role" "cache_warmer"',
        'resource "aws_iam_role_policy" "cache_warmer"',
        'resource "aws_cloudwatch_log_group" "cache_warmer"',
        'resource "aws_lambda_function" "cache_warmer"',
        'resource "aws_cloudwatch_event_rule" "cache_warm"',
        'resource "aws_cloudwatch_event_target" "cache_warm"',
        'resource "aws_lambda_permission" "cache_warm_events"',
        'data "external" "cache_warmer_stage"',
        'data "archive_file" "cache_warmer"',
    ):
        assert needed in main_tf, f"missing: {needed}"


# ──────────────────────────────────────────────────────────────────────────
# ADR-002 — same cache key as classify
# ──────────────────────────────────────────────────────────────────────────


def test_same_model_id_as_classify(main_tf: str) -> None:
    """ADR-002: 워머가 classify 와 동일한 opus MODEL_ID 를 써야 같은 cache key 적중."""
    fn = main_tf[main_tf.index('resource "aws_lambda_function" "cache_warmer"') :]
    fn = fn[: fn.index("depends_on")]
    assert 'MODEL_ID   = "global.anthropic.claude-opus-4-7"' in fn
    assert 'PROMPT_DIR = "/var/task/prompts/v1.0"' in fn
    assert 'handler          = "lambdas.cache_warmer.handler.handler"' in fn


def test_stage_copies_prompts(main_tf: str) -> None:
    """ADR-002: staging 이 lib + prompts + lambdas/cache_warmer 를 복사 (classify 동형)."""
    stage = main_tf[main_tf.index('data "external" "cache_warmer_stage"') :]
    stage = stage[: stage.index('data "archive_file" "cache_warmer"')]
    assert 'cp -R "$SRC_DIR/lib"' in stage
    assert 'cp -R "$SRC_DIR/prompts"' in stage
    assert 'cp -R "$SRC_DIR/lambdas/cache_warmer"' in stage


# ──────────────────────────────────────────────────────────────────────────
# ADR-006 — least privilege IAM
# ──────────────────────────────────────────────────────────────────────────


def test_iam_least_privilege(main_tf: str) -> None:
    """ADR-006: 워머 IAM 은 bedrock:InvokeModel + logs 만. KMS/S3/DDB 권한 없음."""
    pol = main_tf[main_tf.index('resource "aws_iam_role_policy" "cache_warmer"') :]
    pol = pol[: pol.index('resource "aws_cloudwatch_log_group" "cache_warmer"')]
    assert "bedrock:InvokeModel" in pol
    assert "inference-profile/global.anthropic.claude-opus-4-7" in pol
    assert "logs:PutLogEvents" in pol
    # 금지 권한
    assert "kms:" not in pol, "warmer must not hold KMS perms (ADR-006)"
    assert "s3:" not in pol, "warmer must not hold S3 perms (ADR-006)"
    assert "dynamodb:" not in pol, "warmer must not hold DDB perms (ADR-006)"


def test_eventbridge_schedule_is_variable(main_tf: str) -> None:
    """ADR-002: cron schedule 이 하드코딩이 아니라 var.cache_warming_schedule."""
    rule = main_tf[main_tf.index('resource "aws_cloudwatch_event_rule" "cache_warm"') :]
    rule = rule[: rule.index('resource "aws_cloudwatch_event_target" "cache_warm"')]
    assert "schedule_expression = var.cache_warming_schedule" in rule


def test_lambda_permission_principal(main_tf: str) -> None:
    """워머 invoke 권한 principal 은 events.amazonaws.com."""
    perm = main_tf[main_tf.index('resource "aws_lambda_permission" "cache_warm_events"') :]
    assert 'principal     = "events.amazonaws.com"' in perm


# ──────────────────────────────────────────────────────────────────────────
# Outputs + dev wiring
# ──────────────────────────────────────────────────────────────────────────


def test_outputs_count_safe(outputs_tf: str) -> None:
    """null-safe output (count=0 일 때 [0] 참조 에러 방지)."""
    assert "cache_warmer_name" in outputs_tf
    assert "var.enable_cache_warming ?" in outputs_tf


def test_dev_env_wires_flag() -> None:
    """ADR-002: dev root module 이 enable_cache_warming 를 모듈에 전달."""
    dev_main = (DEV_DIR / "main.tf").read_text(encoding="utf-8")
    dev_vars = (DEV_DIR / "variables.tf").read_text(encoding="utf-8")
    assert "enable_cache_warming   = var.enable_cache_warming" in dev_main
    assert 'variable "enable_cache_warming"' in dev_vars
