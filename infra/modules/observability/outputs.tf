output "alerts_topic_arn" {
  value       = aws_sns_topic.alerts.arn
  description = "SNS topic ARN — Slack relay + future PagerDuty subscribers."
}

output "slack_relay_function_name" {
  value       = aws_lambda_function.slack_relay.function_name
  description = "Slack relay Lambda name (debug / smoke)."
}

output "dashboard_name" {
  value       = aws_cloudwatch_dashboard.main.dashboard_name
  description = "CloudWatch dashboard name."
}

output "alarm_names" {
  value = [
    aws_cloudwatch_metric_alarm.sfn_failure.alarm_name,
    aws_cloudwatch_metric_alarm.classify_dlq_backlog.alarm_name,
    aws_cloudwatch_metric_alarm.persist_dlq_backlog.alarm_name,
    aws_cloudwatch_metric_alarm.bedrock_throttle.alarm_name,
    aws_cloudwatch_metric_alarm.hitl_backlog.alarm_name,
  ]
  description = "Names of the 5 alarms — smoke verification target."
}
