output "isolation_security_group_id" {
  description = "The ID of the isolation security group"
  value       = aws_security_group.isolation_sg.id
}

output "sns_topic_arn" {
  description = "The ARN of the security alerts SNS topic"
  value       = aws_sns_topic.security_alerts.arn
}

output "lambda_function_arn" {
  description = "The ARN of the remediation Lambda function"
  value       = aws_lambda_function.remediation_lambda.arn
}