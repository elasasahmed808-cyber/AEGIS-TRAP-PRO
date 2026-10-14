# ---------------------------------------------------------------- finding translator
# Bridges native AWS security findings (GuardDuty / Security Hub) onto the
# custom.security.automation event contract the playbooks listen to.
#
# GuardDuty is on by default. Security Hub is opt-in: GuardDuty findings are
# also imported into Security Hub, so enabling both rules runs the playbooks
# twice per detection (the translator de-duplicates per invocation, but the
# two services deliver the same finding in separate events).

locals {
  translator_statements = [
    {
      Effect   = "Allow"
      Action   = ["events:PutEvents"]
      Resource = "arn:aws:events:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:event-bus/default"
    },
  ]
}

resource "aws_iam_role" "finding_translator" {
  name = "${var.environment}_finding_translator_lambda_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "finding_translator" {
  name = "${var.environment}_finding_translator_policy"
  role = aws_iam_role.finding_translator.id

  # local.logs_statement and the caller-identity/region data sources live in playbooks.tf
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = concat(local.translator_statements, [local.logs_statement])
  })
}

data "archive_file" "finding_translator" {
  type        = "zip"
  source_file = "${path.module}/finding_translator.py"
  output_path = "${path.module}/finding_translator.zip"
}

resource "aws_lambda_function" "finding_translator" {
  function_name    = "${var.environment}_finding_translator"
  filename         = data.archive_file.finding_translator.output_path
  source_code_hash = data.archive_file.finding_translator.output_base64sha256
  role             = aws_iam_role.finding_translator.arn
  handler          = "finding_translator.lambda_handler"
  runtime          = "python3.11"
  timeout          = 60
  memory_size      = 128

  environment {
    variables = {
      MIN_SEVERITY = tostring(var.translator_min_severity)
    }
  }
}

# GuardDuty -> translator. The severity filter at rule level avoids paying for
# a Lambda cold start on findings the code would drop anyway.
resource "aws_cloudwatch_event_rule" "guardduty_findings" {
  count       = var.enable_guardduty_trigger ? 1 : 0
  name        = "${var.environment}-guardduty-findings"
  description = "Forward GuardDuty findings (severity >= ${var.translator_min_severity}) to the finding translator"

  event_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
    detail = {
      severity = [{ numeric = [">=", var.translator_min_severity] }]
    }
  })
}

resource "aws_cloudwatch_event_target" "guardduty_findings" {
  count     = var.enable_guardduty_trigger ? 1 : 0
  rule      = aws_cloudwatch_event_rule.guardduty_findings[0].name
  target_id = "guardduty-translator-target"
  arn       = aws_lambda_function.finding_translator.arn
}

resource "aws_lambda_permission" "guardduty_findings" {
  count         = var.enable_guardduty_trigger ? 1 : 0
  statement_id  = "AllowExecutionFromGuardDutyRule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.finding_translator.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.guardduty_findings[0].arn
}

# Security Hub -> translator (opt-in; see the double-trigger note above).
resource "aws_cloudwatch_event_rule" "securityhub_findings" {
  count       = var.enable_securityhub_trigger ? 1 : 0
  name        = "${var.environment}-securityhub-findings"
  description = "Forward Security Hub findings to the finding translator"

  event_pattern = jsonencode({
    source        = ["aws.securityhub"]
    "detail-type" = ["Security Hub Findings - Imported"]
  })
}

resource "aws_cloudwatch_event_target" "securityhub_findings" {
  count     = var.enable_securityhub_trigger ? 1 : 0
  rule      = aws_cloudwatch_event_rule.securityhub_findings[0].name
  target_id = "securityhub-translator-target"
  arn       = aws_lambda_function.finding_translator.arn
}

resource "aws_lambda_permission" "securityhub_findings" {
  count         = var.enable_securityhub_trigger ? 1 : 0
  statement_id  = "AllowExecutionFromSecurityHubRule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.finding_translator.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.securityhub_findings[0].arn
}
