output "pii_guard_arn" { value = aws_lambda_function.pii_guard.arn }
output "pii_guard_name" { value = aws_lambda_function.pii_guard.function_name }
output "classify_arn" { value = aws_lambda_function.classify.arn }
output "classify_name" { value = aws_lambda_function.classify.function_name }
output "verify_arn" { value = aws_lambda_function.verify.arn }
output "verify_name" { value = aws_lambda_function.verify.function_name }
output "persist_arn" { value = aws_lambda_function.persist.arn }
output "persist_name" { value = aws_lambda_function.persist.function_name }
output "sfn_arn" { value = aws_sfn_state_machine.classify.arn }
output "sfn_name" { value = aws_sfn_state_machine.classify.name }

# ADR-002 cache-warming — count-safe (null when var.enable_cache_warming = false)
output "cache_warmer_name" {
  value = var.enable_cache_warming ? aws_lambda_function.cache_warmer[0].function_name : null
}
output "cache_warm_rule_name" {
  value = var.enable_cache_warming ? aws_cloudwatch_event_rule.cache_warm[0].name : null
}
