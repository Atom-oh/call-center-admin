# PR8 HITL UI — Streamlit on Fargate behind Cognito-authenticated internal ALB.
#
# Spec: docs/superpowers/specs/2026-05-27-hitl-ui-design.md
# ADR matrix (preserved by tests/integration/test_hitl_ui_definition.py):
#   ADR-005 — ECS+ECR (not Lambda); per-Lambda staging pattern does not apply
#   ADR-006 — ECS task role grants ddb/masked/raw KMS only; analytics NOT granted
#   ADR-007 — HITL flows do NOT invoke Step Functions (verified at code layer)
#   ADR-008 — DDB queries use ASCII GSI names + Korean attr placeholders (code layer)
#   ADR-009 — Cognito users are created post-apply by ops, not by Terraform
#   G5/G6   — DDB IAM is Resource-scoped + action-minimal (Query/GetItem/UpdateItem)
#   G7      — ALB internal=true, ingress 10.0.0.0/8
#   G8      — ECR image_tag_mutability = IMMUTABLE
#   G9      — Cognito password policy 12+ chars + 4 char classes
#   G10     — ALB HTTPS listener uses TLS1.3 SSL policy
#   G11     — Log permissions scoped to discrete log group ARN

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
      # ADR-013: CloudFront ACM + WAF v2 (CLOUDFRONT scope) live in us-east-1.
      configuration_aliases = [aws.us_east_1]
    }
  }
}

locals {
  # AI 리뷰 MAJOR (PR #24): CloudFront 스택 (VPC Origin / distribution / WAF) 은
  # ALB HTTPS listener (ap-northeast-2 cert) + CloudFront viewer cert (us-east-1)
  # 가 **둘 다** 주입돼야 켜진다. 하나만 있으면 listener 없는 ALB 를 향해 VPC
  # Origin 이 생성되어 apply 실패하므로 양쪽 gate 로 묶는다.
  cloudfront_enabled = var.acm_certificate_arn != "" && var.acm_certificate_arn_us_east_1 != ""
}

##################################################
# ECR — immutable tags (G8)                      #
##################################################

resource "aws_ecr_repository" "hitl" {
  name                 = "callcenter-${var.env}-hitl-ui"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

##################################################
# Cognito — user pool + 3 groups (ADR-009 / G9)  #
##################################################

resource "aws_cognito_user_pool" "main" {
  name = "callcenter-${var.env}-users"

  password_policy {
    minimum_length    = 12
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = true
  }
}

resource "aws_cognito_user_pool_client" "alb" {
  name            = "callcenter-${var.env}-alb-client"
  user_pool_id    = aws_cognito_user_pool.main.id
  generate_secret = true
  # M2 from 2nd AI review: callback URL is built from var.callback_domain so the
  # actual deploy-time FQDN (which may differ from the convention) is used.
  callback_urls                        = ["https://${var.callback_domain}/oauth2/idpresponse"]
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  allowed_oauth_flows_user_pool_client = true
  supported_identity_providers         = ["COGNITO"]
  # AI review (Suggestions): hide username enumeration responses.
  prevent_user_existence_errors = "ENABLED"
}

resource "aws_cognito_user_pool_domain" "main" {
  domain       = "callcenter-${var.env}-hitl"
  user_pool_id = aws_cognito_user_pool.main.id
}

resource "aws_cognito_user_group" "ops" {
  name         = "ops"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "운영팀 — 검토 큐 관리"
}

resource "aws_cognito_user_group" "analyst" {
  name         = "analyst"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "분석팀 — 검색 / 조회만"
}

resource "aws_cognito_user_group" "compliance" {
  name         = "compliance"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "컴플라이언스 — 원본 STT 감사 다운로드"
}

##################################################
# Security groups — ALB internal + ECS ingress   #
##################################################

# ADR-013 (1차 리뷰 C1/M1 반영): 실제 CloudFront VPC Origin 사용.
# VPC Origin 은 CloudFront edge ↔ ALB 사이를 AWS 내부 네트워크로 잇는 link.
# 인터넷 경유 CF prefix list 와 의미가 달라 ALB SG ingress 는
# VPC CIDR 로 제한한다 (VPC Origin 은 VPC 내부 ENI 로 인입).
data "aws_vpc" "this" {
  id = var.vpc_id
}

resource "aws_security_group" "alb" {
  name_prefix = "callcenter-${var.env}-hitl-alb-"
  description = "Internal ALB ingress for HITL UI (VPC Origin only)"
  vpc_id      = var.vpc_id

  ingress {
    # ADR-013 정정: ALB listener 가 HTTPS(443) 이므로 SG 도 443 을 열어야 한다.
    # 80 만 열면 CloudFront VPC Origin (https-only) → ALB 도달이 런타임에 깨짐
    # (apply 는 성공하므로 silent breakage). VPC Origin 은 AWS internal link 라
    # source 는 VPC CIDR.
    description = "HTTPS from CloudFront VPC Origin (ADR-013, internal AWS link)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.this.cidr_block]
  }

  egress {
    description = "Outbound to ECS tasks"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "ecs" {
  name_prefix = "callcenter-${var.env}-hitl-ecs-"
  description = "ECS task security group (ingress only from ALB SG)"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Streamlit container port from ALB"
    from_port       = 8501
    to_port         = 8501
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "DDB / S3 / KMS over VPC endpoints + public internet for image pull"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

##################################################
# ALB — internal, TLS1.3, authenticate-cognito   #
##################################################

resource "aws_lb" "hitl" {
  name               = "callcenter-${var.env}-hitl"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.private_subnet_ids
}

resource "aws_lb_target_group" "hitl" {
  name        = "callcenter-${var.env}-hitl-tg"
  port        = 8501
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    path                = "/"
    matcher             = "200-399"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# ADR-013 정정 (PR #24 apply 실패): `authenticate-cognito` 액션은 AWS 에서
# HTTPS listener 에서만 지원된다. 따라서 ALB 는 HTTP-only 가 될 수 없고,
# ap-northeast-2 ACM cert 를 가진 HTTPS listener 가 필요하다. CloudFront
# VPC Origin 은 ALB 와 HTTPS 로 통신 (origin_protocol_policy=https-only).
#
# listener 는 ACM cert 주입 후에만 생성 (gate). cert 미발급 시점에는 ALB +
# SG + target group 까지만 stand-up. C1 guard (authenticate-cognito order=1
# → forward order=2) 유지.
resource "aws_lb_listener" "https" {
  count             = var.acm_certificate_arn != "" ? 1 : 0
  load_balancer_arn = aws_lb.hitl.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = var.acm_certificate_arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  default_action {
    order = 1
    type  = "authenticate-cognito"

    authenticate_cognito {
      user_pool_arn       = aws_cognito_user_pool.main.arn
      user_pool_client_id = aws_cognito_user_pool_client.alb.id
      user_pool_domain    = aws_cognito_user_pool_domain.main.domain
    }
  }

  default_action {
    order            = 2
    type             = "forward"
    target_group_arn = aws_lb_target_group.hitl.arn
  }
}

###############################################################
# ADR-013: CloudFront distribution + VPC Origin + WAF v2      #
###############################################################

# WAF v2 web ACL (CLOUDFRONT scope is us-east-1 only).
resource "aws_wafv2_web_acl" "hitl" {
  count    = var.enable_waf && local.cloudfront_enabled ? 1 : 0
  provider = aws.us_east_1
  name     = "callcenter-${var.env}-hitl"
  scope    = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "AWS-AWSManagedRulesCommonRuleSet"
    priority = 0

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "common-rules"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-AWSManagedRulesKnownBadInputsRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "callcenter-${var.env}-hitl-waf"
    sampled_requests_enabled   = true
  }
}

# C1 from 1st AI review: 실제 CloudFront VPC Origin endpoint 등록.
# CloudFront edge ↔ ALB 간 트래픽이 AWS internal network 로 직행 —
# public 인터넷 경유 0. ALB 가 internal=true 여도 도달 가능.
# AI 리뷰 MAJOR (PR #24): VPC Origin 은 https-only 라 ALB 443 listener 가
# 있어야 생성 가능. listener 는 ap-northeast-2 cert (var.acm_certificate_arn)
# gate 이므로, VPC Origin / distribution / WAF 도 **양쪽 cert** 가 모두 주입돼야
# 켜진다 (local.cloudfront_enabled). us-east-1 cert 만 주입 시 listener 없는
# ALB 를 향해 VPC Origin 이 생성되어 apply 실패하는 것을 차단.
resource "aws_cloudfront_vpc_origin" "hitl" {
  count = local.cloudfront_enabled ? 1 : 0

  vpc_origin_endpoint_config {
    name = "callcenter-${var.env}-hitl-vpc-origin"
    arn  = aws_lb.hitl.arn
    # ADR-013 정정: ALB listener 가 HTTPS (authenticate-cognito 제약) 이므로
    # VPC Origin 도 ALB 와 HTTPS 로 통신.
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "https-only"

    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }
}

# CloudFront distribution — gated on BOTH certs (local.cloudfront_enabled).
# Without them the CF is omitted; ALB stands up (no listener) for skeleton state.
resource "aws_cloudfront_distribution" "hitl" {
  count = local.cloudfront_enabled ? 1 : 0

  enabled         = true
  is_ipv6_enabled = true
  comment         = "callcenter-${var.env}-hitl"

  # Cognito authenticate-cognito sets cookies + redirects — CF must respect
  # the alternate callback FQDN.
  aliases = [var.callback_domain]

  origin {
    # C1 fix: VPC Origin via aws_cloudfront_vpc_origin resource. CloudFront
    # uses an AWS-internal link to reach the (internal) ALB. domain_name is
    # still required for SNI / host header.
    domain_name = aws_lb.hitl.dns_name
    origin_id   = "hitl-alb"

    vpc_origin_config {
      vpc_origin_id = aws_cloudfront_vpc_origin.hitl[0].id
    }
  }

  default_cache_behavior {
    target_origin_id       = "hitl-alb"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # M2 from 1st AI review: legacy forwarded_values { headers=["*"] } 는 invalid.
    # AWS managed policies 사용:
    #   - cache_policy_id          = Managed-CachingDisabled
    #     (4135ea2d-6df8-44a3-9df3-4b5a84be39ad)
    #   - origin_request_policy_id = Managed-AllViewer
    #     (216adef6-5c7f-47e4-b989-5492eafa07d3)
    # Streamlit 의 websocket / Set-Cookie / Authorization 모두 보존.
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3"
  }

  viewer_certificate {
    acm_certificate_arn      = var.acm_certificate_arn_us_east_1
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  # M3 from 1st AI review: ADR-013 의 "외부 접근 가능" 의도와 KR-only whitelist 가
  # 모순이었음. 기본 restriction_type="none" 으로 변경 — 외근 / 출장 시 접근 가능.
  # 접근 제어는 다층 (1) Cognito 인증 (2) WAF managed rules. 사내 IP allowlist 가
  # 필요해지면 var.geo_restriction_locations 노출 추가.
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  web_acl_id = length(aws_wafv2_web_acl.hitl) > 0 ? aws_wafv2_web_acl.hitl[0].arn : null

  tags = {
    Name = "callcenter-${var.env}-hitl"
  }
}

##################################################
# ECS cluster + service                          #
##################################################

resource "aws_ecs_cluster" "main" {
  name = "callcenter-${var.env}-hitl"
}

resource "aws_cloudwatch_log_group" "hitl" {
  name              = "/ecs/callcenter-${var.env}-hitl"
  retention_in_days = var.log_retention_days
}

# Separate audit log group (M3 from AI review): every correction / skip /
# compliance presigned URL emission writes a structured JSON record here so
# CloudTrail S3 GetObject events can be correlated with the Cognito user that
# initiated the download. Retention is longer than the app log group because
# the audit trail must outlive the application logs (finance domain).
resource "aws_cloudwatch_log_group" "hitl_audit" {
  name              = "/hitl-ui/audit/callcenter-${var.env}"
  retention_in_days = var.audit_retention_days
}

resource "aws_iam_role" "ecs_task" {
  name = "callcenter-${var.env}-hitl-task"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# G5 / G6 / G11 + ADR-006: DDB scoped to table+index, only Query/GetItem/UpdateItem,
# S3 GetObject for masked+raw, KMS Decrypt for 3 CMK only, logs scoped to log group.
resource "aws_iam_role_policy" "ecs_task" {
  role = aws_iam_role.ecs_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:Query",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
        ]
        Resource = [
          var.ddb_consult_arn,
          "${var.ddb_consult_arn}/index/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${var.bucket_masked_arn}/*", "${var.bucket_raw_arn}/*"]
      },
      {
        Effect = "Allow"
        Action = ["kms:Decrypt"]
        # ADR-006: ddb (read encrypted items) + masked (transcript) + raw
        # (compliance presigned download). analytics CMK is intentionally absent.
        Resource = [
          var.kms_ddb_arn,
          var.kms_masked_arn,
          var.kms_raw_arn,
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = [
          "${aws_cloudwatch_log_group.hitl.arn}:*",
          "${aws_cloudwatch_log_group.hitl_audit.arn}:*",
        ]
      },
    ]
  })
}

resource "aws_iam_role" "ecs_exec" {
  name = "callcenter-${var.env}-hitl-exec"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_exec" {
  role       = aws_iam_role.ecs_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_task_definition" "hitl" {
  family                   = "callcenter-${var.env}-hitl"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_exec.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name = "streamlit"
      # M1 from AI Code Review: variable image tag so subsequent deploys can
      # push a new tag against the IMMUTABLE ECR repository. PR10 CI/CD
      # passes the commit SHA.
      image     = "${aws_ecr_repository.hitl.repository_url}:${var.image_tag}"
      essential = true
      portMappings = [{
        containerPort = 8501
        hostPort      = 8501
      }]
      environment = [
        { name = "ENV", value = var.env },
        { name = "DDB_TABLE", value = "callcenter-${var.env}-consult-results" },
        # M2: ALB region for OIDC public key fetch.
        { name = "ALB_REGION", value = var.alb_region },
        # ADR-011 hardening: our own ALB ARN. hitl_lib.auth rejects any OIDC
        # token whose JWT `signer` header != this value, blocking tokens minted
        # by a different ALB in the same region (the public-key endpoint is
        # region-wide). Injecting the ARN here is what activates the gate.
        { name = "ALB_ARN", value = aws_lb.hitl.arn },
        # M3: audit log group name for the auth/compliance/correction trail.
        { name = "AUDIT_LOG_GROUP", value = aws_cloudwatch_log_group.hitl_audit.name },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.hitl.name
          awslogs-region        = "ap-northeast-2"
          awslogs-stream-prefix = "streamlit"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "hitl" {
  # ADR-013 정정: ECS service 의 load_balancer 블록은 target group 이 LB 와
  # 연결(listener)되어 있어야 attach 가능. listener 가 ACM cert gate 이므로
  # ECS service 도 동일 gate. cert 미발급 시점에는 cluster / task_definition /
  # IAM / log group / ECR / Cognito 까지만 stand-up.
  count           = var.acm_certificate_arn != "" ? 1 : 0
  name            = "callcenter-${var.env}-hitl"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.hitl.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.hitl.arn
    container_name   = "streamlit"
    container_port   = 8501
  }

  depends_on = [aws_lb_listener.https]
}
