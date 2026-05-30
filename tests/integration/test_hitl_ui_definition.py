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
    import re

    assert 'resource "aws_cognito_user_pool" "main"' in main_tf
    pool_block = main_tf.split('aws_cognito_user_pool" "main"')[1].split('resource "aws_')[0]
    # m6 from AI review: regex tolerates `terraform fmt` alignment changes.
    assert re.search(r"minimum_length\s*=\s*12\b", pool_block), (
        "minimum_length must be 12 (any spacing)"
    )
    for req in (
        "require_lowercase",
        "require_uppercase",
        "require_numbers",
        "require_symbols",
    ):
        # `<req>\s*=\s*true` — also tolerates alignment.
        assert re.search(rf"{req}\s*=\s*true\b", pool_block), (
            f"{req} must be set to true (any spacing)"
        )


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
    """G7 + M1 from 1st AI review: ALB internal. With real VPC Origin (C1 fix),
    ingress source becomes the VPC CIDR — VPC Origin is an AWS-internal link
    that arrives at the ALB from within the VPC. The CloudFront managed prefix
    list `cloudfront.origin-facing` is for internet-routed CF, NOT VPC Origin.
    """
    import re

    assert 'resource "aws_lb" "hitl"' in main_tf
    lb_block = main_tf.split('aws_lb" "hitl"')[1].split('resource "aws_')[0]
    assert re.search(r"internal\s*=\s*true\b", lb_block), "ALB must be internal"
    sg_alb_block = main_tf.split('aws_security_group" "alb"')[1].split('resource "aws_')[0]
    assert '"0.0.0.0/0"' not in sg_alb_block.split("ingress")[1].split("egress")[0], (
        "ALB SG must not have 0.0.0.0/0 ingress"
    )
    # M1 fix: ingress source is VPC CIDR (data.aws_vpc.this.cidr_block), not the
    # internet-routed CloudFront prefix list.
    assert "data.aws_vpc.this.cidr_block" in main_tf, (
        "ALB SG ingress must use VPC CIDR for VPC Origin traffic (ADR-013 M1 fix)"
    )
    assert "com.amazonaws.global.cloudfront.origin-facing" not in main_tf, (
        "ALB SG must NOT use the internet-routed CF prefix list — that contradicts VPC Origin"
    )


def test_alb_listener_is_http_only_with_tls_at_cloudfront(main_tf: str) -> None:
    """ADR-013 supersedes G10: TLS terminates at CloudFront, ALB receives HTTP
    from the VPC Origin. There must be an HTTP listener and no HTTPS listener
    holding an ACM cert directly."""
    assert 'resource "aws_lb_listener" "http"' in main_tf
    assert 'resource "aws_lb_listener" "https"' not in main_tf, (
        "ALB must not terminate TLS — that is CloudFront's job (ADR-013)"
    )


def test_alb_listener_enforces_authenticate_cognito_before_forward(main_tf: str) -> None:
    """C1 guard (2nd AI review): the HTTP listener must run authenticate-cognito
    BEFORE forward. The default_action chain remains identical post-ADR-013.
    """
    listener_block = main_tf.split('aws_lb_listener" "http"')[1].split('resource "aws_')[0]
    assert "authenticate-cognito" in listener_block, (
        "default_action must include authenticate-cognito"
    )
    assert (
        'type             = "forward"' in listener_block or 'type = "forward"' in listener_block
    ), "default_action must include forward"
    auth_idx = listener_block.find("authenticate-cognito")
    fwd_idx = listener_block.find('type             = "forward"')
    if fwd_idx == -1:
        fwd_idx = listener_block.find('type = "forward"')
    assert auth_idx < fwd_idx, "authenticate-cognito must precede forward in default_action"


def test_alb_has_no_path_pattern_forward_rule(main_tf: str) -> None:
    """C1 negative guard: there must be NO listener_rule with `path_pattern = "/*"`
    forwarding to the target group. That rule would short-circuit default_action
    and bypass Cognito authentication entirely."""
    # If any aws_lb_listener_rule exists, none of them may use path_pattern `/*` + forward.
    if "aws_lb_listener_rule" not in main_tf:
        return  # No rules at all is fine — default_action handles it.
    # Search for the pattern "/*" combined with a forward action in the same block.
    rule_blocks = main_tf.split('resource "aws_lb_listener_rule"')[1:]
    for block in rule_blocks:
        # The block ends at the next resource or EOF.
        block = block.split('resource "aws_')[0]
        if "path_pattern" in block and '"/*"' in block and 'type             = "forward"' in block:
            raise AssertionError(
                "listener_rule with path_pattern=`/*` + forward bypasses Cognito auth"
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


# ──────────────────────────────────────────────────────────────────────────
# ADR-013 — CloudFront + VPC Origin + WAF
# ──────────────────────────────────────────────────────────────────────────


def test_cloudfront_distribution_defined(main_tf: str) -> None:
    """ADR-013: CloudFront distribution fronts the internal ALB via VPC Origin."""
    assert 'resource "aws_cloudfront_distribution" "hitl"' in main_tf


def test_cloudfront_uses_vpc_origin_resource(main_tf: str) -> None:
    """C1 from 1st AI review: CloudFront must reach the internal ALB via a real
    VPC Origin (aws_cloudfront_vpc_origin resource + vpc_origin_config block).
    custom_origin_config alone is internet-routed and CANNOT reach internal=true ALBs.
    """
    assert 'resource "aws_cloudfront_vpc_origin" "hitl"' in main_tf, (
        "Must declare aws_cloudfront_vpc_origin resource (ADR-013 C1 fix)"
    )
    cf_block = main_tf.split('aws_cloudfront_distribution" "hitl"')[1].split('resource "aws_')[0]
    assert "vpc_origin_config" in cf_block, (
        "CF origin block must use vpc_origin_config (not custom_origin_config)"
    )
    assert "aws_cloudfront_vpc_origin.hitl[0].id" in cf_block, (
        "vpc_origin_config must reference the aws_cloudfront_vpc_origin resource"
    )


def test_cloudfront_vpc_origin_points_to_alb_with_http_only(main_tf: str) -> None:
    """ADR-013: VPC Origin endpoint targets the ALB ARN with HTTP-only protocol
    (TLS terminates at CF edge)."""
    vpc_origin_block = main_tf.split('aws_cloudfront_vpc_origin" "hitl"')[1].split(
        'resource "aws_'
    )[0]
    assert "aws_lb.hitl.arn" in vpc_origin_block, "VPC Origin must target the ALB ARN"
    assert 'origin_protocol_policy = "http-only"' in vpc_origin_block, (
        "CF → ALB must be HTTP-only (TLS at CF edge per ADR-013)"
    )


def test_cloudfront_viewer_uses_acm_us_east_1_and_tls12_min(main_tf: str) -> None:
    """ADR-013: viewer-side ACM must be the us-east-1 public cert; min TLS 1.2."""
    cf_block = main_tf.split('aws_cloudfront_distribution" "hitl"')[1].split('resource "aws_')[0]
    assert "var.acm_certificate_arn_us_east_1" in cf_block
    assert 'minimum_protocol_version = "TLSv1.2_2021"' in cf_block


def test_waf_v2_attached_to_cloudfront_scope(main_tf: str) -> None:
    """ADR-013: WAF v2 web ACL is CLOUDFRONT-scoped, attached via web_acl_id."""
    assert 'resource "aws_wafv2_web_acl" "hitl"' in main_tf
    waf_block = main_tf.split('aws_wafv2_web_acl" "hitl"')[1].split('resource "aws_')[0]
    assert 'scope    = "CLOUDFRONT"' in waf_block or 'scope = "CLOUDFRONT"' in waf_block
    assert "provider = aws.us_east_1" in waf_block, (
        "WAF v2 CLOUDFRONT scope must live in us-east-1 provider alias"
    )
    cf_block = main_tf.split('aws_cloudfront_distribution" "hitl"')[1].split('resource "aws_')[0]
    assert "web_acl_id" in cf_block, "CloudFront must wire the WAF web_acl_id"


def test_cloudfront_alias_uses_callback_domain(main_tf: str) -> None:
    """ADR-013: CloudFront `aliases` matches the public callback_domain."""
    cf_block = main_tf.split('aws_cloudfront_distribution" "hitl"')[1].split('resource "aws_')[0]
    assert "var.callback_domain" in cf_block


def test_provider_us_east_1_alias_required(main_tf: str) -> None:
    """ADR-013: module declares the us-east-1 provider configuration alias."""
    assert "configuration_aliases" in main_tf
    assert "aws.us_east_1" in main_tf


def test_cloudfront_uses_managed_cache_and_origin_request_policies(main_tf: str) -> None:
    """M2 from 1st AI review: legacy forwarded_values { headers=["*"] } 는 invalid.
    Managed-CachingDisabled (4135ea2d-...) + Managed-AllViewer (216adef6-...) 사용.
    """
    cf_block = main_tf.split('aws_cloudfront_distribution" "hitl"')[1].split('resource "aws_')[0]
    code_only = _strip_comments(cf_block)
    assert "forwarded_values" not in code_only, (
        "default_cache_behavior must NOT use legacy forwarded_values (M2 fix)"
    )
    # AWS-managed policy IDs (well-known constants).
    assert "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" in cf_block, (
        "cache_policy_id must reference Managed-CachingDisabled"
    )
    assert "216adef6-5c7f-47e4-b989-5492eafa07d3" in cf_block, (
        "origin_request_policy_id must reference Managed-AllViewer (preserves headers/cookies)"
    )


def test_cloudfront_geo_restriction_allows_external_access(main_tf: str) -> None:
    """M3 from 1st AI review: ADR-013 Positive 항목 "외부 접근" 의도와 KR-only
    whitelist 모순. restriction_type = "none" — Cognito + WAF 가 접근 제어."""
    cf_block = main_tf.split('aws_cloudfront_distribution" "hitl"')[1].split('resource "aws_')[0]
    assert 'restriction_type = "none"' in cf_block, (
        "geo_restriction must be `none` to honor ADR-013 external access goal"
    )
    assert '"KR"' not in cf_block, "KR-only whitelist contradicts external access intent"
