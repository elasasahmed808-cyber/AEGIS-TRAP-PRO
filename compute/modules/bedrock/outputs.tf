output "guardrail_id" { value = local.guardrail_id }
output "guardrail_arn" { value = local.guardrail_arn }
output "guardrail_version" { value = local.guardrail_version }
output "logs_bucket" { value = aws_s3_bucket.logs.id }
