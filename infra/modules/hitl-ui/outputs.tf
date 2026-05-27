output "alb_dns_name" {
  value       = aws_lb.hitl.dns_name
  description = "Internal ALB DNS — point Route53 private zone at this."
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
