output "alerts_topic_arn" {
  value       = aws_sns_topic.alerts.arn
  description = "SNS topic ARN that receives all alarm notifications."
}

output "slack_relay_function_name" {
  value       = aws_lambda_function.slack_relay.function_name
  description = "Slack relay Lambda function name (debug / smoke test)."
}

output "dashboard_name" {
  value       = aws_cloudwatch_dashboard.main.dashboard_name
  description = "CloudWatch dashboard name (also accessible via AWS console)."
}

output "alarm_names" {
  value = [
    aws_cloudwatch_metric_alarm.sfn_failure.alarm_name,
    aws_cloudwatch_metric_alarm.classify_dlq_backlog.alarm_name,
    aws_cloudwatch_metric_alarm.persist_dlq_backlog.alarm_name,
    aws_cloudwatch_metric_alarm.bedrock_throttle.alarm_name,
    aws_cloudwatch_metric_alarm.hitl_backlog.alarm_name,
  ]
  description = "Full list of CloudWatch metric alarms wired into the alerts topic."
}
