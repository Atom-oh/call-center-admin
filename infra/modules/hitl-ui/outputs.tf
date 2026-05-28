output "alb_dns_name" {
  value = aws_lb.hitl.dns_name
  # m2: when acm_certificate_arn is empty the ALB has no HTTPS listener and the
  # DNS name resolves to an unreachable load balancer. Callers must not point
  # Route53 at this until the cert is wired.
  description = "Internal ALB DNS — reachable only after acm_certificate_arn is set."
}

output "audit_log_group_name" {
  value       = aws_cloudwatch_log_group.hitl_audit.name
  description = "Audit CloudWatch log group — Cognito user → DDB UpdateItem / S3 presigned URL trail."
}

output "ecr_repo_url" {
  value       = aws_ecr_repository.hitl.repository_url
  description = "ECR repository for Streamlit image — used by CI/CD docker push."
}

output "cognito_pool_id" {
  value       = aws_cognito_user_pool.main.id
  description = "Cognito user pool ID — used by ops to admin-create-user."
}

output "ecs_cluster_name" {
  value       = aws_ecs_cluster.main.name
  description = "ECS cluster name — used for `aws ecs update-service`."
}

output "ecs_service_name" {
  value       = aws_ecs_service.hitl.name
  description = "ECS service name — used for `aws ecs update-service --force-new-deployment`."
}
