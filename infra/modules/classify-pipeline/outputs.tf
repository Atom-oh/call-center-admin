output "pii_guard_arn" { value = aws_lambda_function.pii_guard.arn }
output "pii_guard_name" { value = aws_lambda_function.pii_guard.function_name }
output "classify_arn" { value = aws_lambda_function.classify.arn }
output "classify_name" { value = aws_lambda_function.classify.function_name }
