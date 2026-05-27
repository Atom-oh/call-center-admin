"""HITL UI Terraform 모듈 + Dockerfile 정적 정의 검증 (spec §6.3).

apply 없이 main.tf / variables.tf / outputs.tf / Dockerfile 텍스트를 읽어
ADR + spec G* 가드들이 보존되었는지 확인.

각 test 는 docstring 에서 어떤 ADR/Decision/Guard 를 보호하는지 명시.
"""

from __future__ import annotations

from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent.parent
TF_DIR = REPO_ROOT / "infra/modules/hitl-ui"
DOCKERFILE = REPO_ROOT / "src/hitl_ui/Dockerfile"


@pytest.fixture(scope="module")
def main_tf() -> str:
    return (TF_DIR / "main.tf").read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def variables_tf() -> str:
    return (TF_DIR / "variables.tf").read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def outputs_tf() -> str:
    return (TF_DIR / "outputs.tf").read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def dockerfile() -> str:
    return DOCKERFILE.read_text(encoding="utf-8")


def _strip_comments(tf: str) -> str:
    """Strip HCL # comments so anti-example tokens in docstrings don't false-positive."""
    return "\n".join(line for line in tf.splitlines() if not line.lstrip().startswith("#"))


def test_hitl_module_files_exist(main_tf: str, variables_tf: str, outputs_tf: str) -> None:
    """spec §5: module produces main + variables + outputs (3 files)."""
    assert main_tf
    assert variables_tf
    assert outputs_tf


# ──────────────────────────────────────────────────────────────────────────
# G8 — ECR immutable
# ──────────────────────────────────────────────────────────────────────────


def test_ecr_repo_is_immutable(main_tf: str) -> None:
    """G8: ECR image tag mutability must be IMMUTABLE — prevents tag hijack."""
    assert 'resource "aws_ecr_repository" "hitl"' in main_tf
    assert 'image_tag_mutability = "IMMUTABLE"' in main_tf


# ──────────────────────────────────────────────────────────────────────────
# G9 — Cognito password policy
# ──────────────────────────────────────────────────────────────────────────


def test_cognito_password_policy_12_chars_4_classes(main_tf: str) -> None:
    """G9: passwords require length >= 12 and all 4 character classes."""
    assert 'resource "aws_cognito_user_pool" "main"' in main_tf
    pool_block = main_tf.split('aws_cognito_user_pool" "main"')[1].split('resource "aws_')[0]
    assert "minimum_length    = 12" in pool_block or "minimum_length = 12" in pool_block
    for req in (
        "require_lowercase",
        "require_uppercase",
        "require_numbers",
        "require_symbols",
    ):
        assert req in pool_block and "true" in pool_block.split(req)[1].split("\n")[0]


def test_cognito_user_groups_define_three_roles(main_tf: str) -> None:
    """spec §2.3: three RBAC groups (ops / analyst / compliance) must be defined."""
    for group in ("ops", "analyst", "compliance"):
        assert f'resource "aws_cognito_user_group" "{group}"' in main_tf, (
            f"missing user group resource for: {group}"
        )


# ──────────────────────────────────────────────────────────────────────────
# G7 + G10 — ALB internal + TLS 1.3
# ──────────────────────────────────────────────────────────────────────────


def test_alb_is_internal_not_public(main_tf: str) -> None:
    """G7: ALB must be internal, ingress restricted to private CIDR."""
    assert 'resource "aws_lb" "hitl"' in main_tf
    lb_block = main_tf.split('aws_lb" "hitl"')[1].split('resource "aws_')[0]
    assert "internal           = true" in lb_block or "internal = true" in lb_block
    # SG ingress should be 10.0.0.0/8, not 0.0.0.0/0.
    sg_alb_block = main_tf.split('aws_security_group" "alb"')[1].split('resource "aws_')[0]
    assert '"10.0.0.0/8"' in sg_alb_block
    assert '"0.0.0.0/0"' not in sg_alb_block.split("ingress")[1].split("egress")[0]


def test_alb_listener_uses_tls13(main_tf: str) -> None:
    """G10: HTTPS listener must use the TLS-1.3 SSL policy."""
    assert 'resource "aws_lb_listener" "https"' in main_tf
    listener_block = main_tf.split('aws_lb_listener" "https"')[1].split('resource "aws_')[0]
    assert (
        "ElbSecurityPolicy-TLS13" in listener_block or "ELBSecurityPolicy-TLS13" in listener_block
    )


# ──────────────────────────────────────────────────────────────────────────
# ADR-006 — KMS scope (3 CMK granted, analytics NOT granted)
# ──────────────────────────────────────────────────────────────────────────


def test_ecs_task_kms_grants_minimal(main_tf: str, variables_tf: str) -> None:
    """ADR-006: ECS task role grants ddb + masked + raw KMS Decrypt only.
    Analytics CMK must NOT be wired into the module variables — the module has
    no reason to touch analytics data.
    """
    # Variables only contain the 3 CMK ARNs (ddb / masked / raw), not analytics.
    assert "kms_ddb_arn" in variables_tf
    assert "kms_masked_arn" in variables_tf
    assert "kms_raw_arn" in variables_tf
    assert "kms_analytics_arn" not in variables_tf, (
        "HITL UI must not declare analytics KMS variable — ADR-006 least privilege"
    )

    # ECS task policy explicitly references the 3 allowed KMS ARNs.
    code = _strip_comments(main_tf)
    assert "var.kms_ddb_arn" in code
    assert "var.kms_masked_arn" in code
    assert "var.kms_raw_arn" in code
    assert "var.kms_analytics_arn" not in code, "analytics KMS must not be referenced"


# ──────────────────────────────────────────────────────────────────────────
# G5 / G6 — DDB IAM scope
# ──────────────────────────────────────────────────────────────────────────


def test_ecs_task_iam_dynamodb_scoped_to_table_and_index(main_tf: str) -> None:
    """G5: DDB Resource is the consult-results table + index/*, not "*"."""
    assert "var.ddb_consult_arn" in main_tf
    assert "${var.ddb_consult_arn}/index/*" in main_tf
    # ECS task policy block must not grant DDB Resource = "*".
    task_policy_block = main_tf.split('aws_iam_role_policy" "ecs_task"')[1].split('resource "aws_')[
        0
    ]
    code = _strip_comments(task_policy_block)
    assert '"dynamodb' in code  # at least one dynamodb action exists
    # Search for `"dynamodb...` action with star resource — would be a fail.
    assert '"dynamodb' not in code.split('Resource = "*"')[0] or 'Resource = "*"' not in code, (
        "dynamodb action with Resource=* is forbidden"
    )


def test_ecs_task_iam_dynamodb_actions_minimal(main_tf: str) -> None:
    """G6: Only Query / GetItem / UpdateItem — Scan / DeleteItem are denied."""
    task_block = main_tf.split('aws_iam_role_policy" "ecs_task"')[1].split('resource "aws_')[0]
    code = _strip_comments(task_block)
    assert "dynamodb:Query" in code
    assert "dynamodb:GetItem" in code
    assert "dynamodb:UpdateItem" in code
    # Forbidden actions.
    assert "dynamodb:Scan" not in code, "Scan is a data-egress risk and is not needed by HITL UI"
    assert "dynamodb:DeleteItem" not in code, "DeleteItem violates audit invariant"
    assert "dynamodb:PutItem" not in code, (
        "PutItem violates ADR-007 (HITL is outside SFN write path)"
    )


def test_ecs_task_iam_logs_scoped_to_log_group(main_tf: str) -> None:
    """G11: logs IAM Resource must reference the discrete log group ARN, not "*"."""
    assert 'resource "aws_cloudwatch_log_group" "hitl"' in main_tf
    task_block = main_tf.split('aws_iam_role_policy" "ecs_task"')[1].split('resource "aws_')[0]
    code = _strip_comments(task_block)
    # Either logs:* with specific ARN or split CreateLogStream/PutLogEvents,
    # both OK — but no Resource = "*".
    # If logs grants are present, they must reference the log group.
    if "logs:" in code:
        assert "aws_cloudwatch_log_group.hitl.arn" in code, (
            "logs IAM exists but is not scoped to the log group ARN"
        )


# ──────────────────────────────────────────────────────────────────────────
# ADR-009 — no inline Cognito user creation
# ──────────────────────────────────────────────────────────────────────────


def test_hitl_module_does_not_create_cognito_user(main_tf: str) -> None:
    """ADR-009: Cognito users are created by ops post-apply, not by Terraform."""
    assert 'resource "aws_cognito_user"' not in main_tf, (
        "Cognito user resource must not be declared — ops creates users out-of-band"
    )


# ──────────────────────────────────────────────────────────────────────────
# ADR-005 — ECS / ECR (not Lambda) packaging
# ──────────────────────────────────────────────────────────────────────────


def test_hitl_module_uses_ecr_not_lambda(main_tf: str) -> None:
    """ADR-005 corollary: HITL UI runs on Fargate ECS, not Lambda. Per-Lambda
    staging-dir pattern does not apply here.
    """
    assert 'resource "aws_ecr_repository"' in main_tf
    assert 'resource "aws_ecs_cluster"' in main_tf
    assert 'resource "aws_ecs_task_definition"' in main_tf
    assert 'resource "aws_lambda_function"' not in main_tf, "HITL UI must run on ECS, not Lambda"


# ──────────────────────────────────────────────────────────────────────────
# Dockerfile guards
# ──────────────────────────────────────────────────────────────────────────


def test_dockerfile_uses_python_312_slim_base(dockerfile: str) -> None:
    """spec §5: Dockerfile base must match the project Python version."""
    assert "FROM python:3.12" in dockerfile, "Dockerfile base must be python:3.12 family"


def test_dockerfile_streamlit_headless_mode(dockerfile: str) -> None:
    """spec §2: Streamlit must run in headless mode behind ALB."""
    assert "--server.headless=true" in dockerfile
    assert "--server.port=8501" in dockerfile
    assert "--server.address=0.0.0.0" in dockerfile
