output "isolation_security_group_id" {
  description = "The ID of the isolation security group"
  value       = aws_security_group.isolation_sg.id
}

output "sns_topic_arn" {
  description = "The ARN of the security alerts SNS topic"
  value       = aws_sns_topic.security_alerts.arn
}

output "quarantine_swap_lambda_arn" {
  description = "The ARN of the quarantine-swap Lambda function"
  value       = aws_lambda_function.quarantine_swap.arn
}

output "playbook_lambda_arns" {
  description = "ARNs of the responder Lambdas (asg-detach, key-disable-revoke, ebs-snapshot, generic-alert)"
  value       = { for k, f in aws_lambda_function.playbook : k => f.arn }
}

output "evidence_bucket_name" {
  description = "S3 bucket holding forensic chain-of-custody records"
  value       = aws_s3_bucket.evidence.id
}

output "finding_translator_lambda_arn" {
  description = "ARN of the Lambda translating GuardDuty/Security Hub findings into playbook events"
  value       = aws_lambda_function.finding_translator.arn
}

output "finding_translator_rule_arns" {
  description = "EventBridge rules feeding the finding translator (empty map entries are disabled)"
  value = merge(
    var.enable_guardduty_trigger ? { guardduty = aws_cloudwatch_event_rule.guardduty_findings[0].arn } : {},
    var.enable_securityhub_trigger ? { securityhub = aws_cloudwatch_event_rule.securityhub_findings[0].arn } : {},
  )
}
