output "alb_dns_name" {
  value       = aws_lb.hitl.dns_name
  description = "Internal ALB DNS — CloudFront VPC Origin target (ADR-013). Not user-facing."
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

# ADR-013: CloudFront distribution + domain (user-facing endpoint).
output "cloudfront_distribution_id" {
  value       = length(aws_cloudfront_distribution.hitl) > 0 ? aws_cloudfront_distribution.hitl[0].id : ""
  description = "CloudFront distribution ID — empty until acm_certificate_arn_us_east_1 is set."
}

output "cloudfront_domain_name" {
  value       = length(aws_cloudfront_distribution.hitl) > 0 ? aws_cloudfront_distribution.hitl[0].domain_name : ""
  description = "CloudFront managed domain (xyz.cloudfront.net). Point Route53 alias at this if callback_domain differs."
}
