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

# ADR-013: ALB ingress restricted to CloudFront origin-facing IPs (managed
# prefix list). Direct intranet ingress is no longer needed — all traffic
# arrives via CloudFront VPC Origin.
data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb" {
  name_prefix = "callcenter-${var.env}-hitl-alb-"
  description = "Internal ALB ingress for HITL UI (CloudFront origin only)"
  vpc_id      = var.vpc_id

  ingress {
    description     = "HTTP from CloudFront edge (ADR-013)"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront_origin_facing.id]
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
  # ADR-013: target group is created unconditionally now — listener attaches it
  # immediately via HTTP, and CloudFront becomes the public entry point.
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

# ADR-013: HTTP listener — TLS is terminated at CloudFront, ALB receives
# already-decrypted traffic via the VPC Origin (AWS internal link). The
# authenticate-cognito + forward chain stays identical (C1 guard from 2nd AI
# review).
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.hitl.arn
  port              = 80
  protocol          = "HTTP"

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
  count    = var.enable_waf && var.acm_certificate_arn_us_east_1 != "" ? 1 : 0
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

# CloudFront distribution — gated on the us-east-1 ACM certificate being issued.
# Without the cert the CF is omitted; the ALB still stands up and can be
# reached over the VPC for internal smoke tests but no public DNS is bound.
resource "aws_cloudfront_distribution" "hitl" {
  count = var.acm_certificate_arn_us_east_1 != "" ? 1 : 0

  enabled         = true
  is_ipv6_enabled = true
  comment         = "callcenter-${var.env}-hitl"

  # Cognito authenticate-cognito sets cookies + redirects — CF must respect
  # the alternate callback FQDN.
  aliases = [var.callback_domain]

  origin {
    # VPC Origin: CloudFront talks to the ALB over the AWS network. Origin
    # protocol is HTTP because TLS terminates at the CF edge.
    domain_name = aws_lb.hitl.dns_name
    origin_id   = "hitl-alb"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "hitl-alb"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    # No caching for dynamic HITL pages — Streamlit responses are user-specific.
    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0

    forwarded_values {
      query_string = true
      headers      = ["*"]
      cookies {
        forward = "all"
      }
    }
  }

  viewer_certificate {
    acm_certificate_arn      = var.acm_certificate_arn_us_east_1
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["KR"]
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
  # ADR-013: TG + HTTP listener are now created unconditionally, so the ECS
  # service can stand up alongside them. CloudFront (gated on us-east-1 ACM)
  # is the only piece that waits for the cert.
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
}
