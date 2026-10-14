resource "aws_ssm_parameter" "apmix_api_key" {
  name  = "/${var.name_prefix}/apmix-api-key"
  type  = "SecureString"
  value = var.apmix_api_key_value
  # no key_id = uses the AWS-managed key (alias/aws/ssm) automatically

  tags = {
    Name = "${var.name_prefix}-apmix-api-key"
  }

  lifecycle {
    ignore_changes = [value]
  }
}