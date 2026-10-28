# 1. Isolation Security Group (بلا أي Inbound أو Outbound Rules)
resource "aws_security_group" "isolation_sg" {
  name        = "${var.environment}-quarantine-isolation-sg"
  description = "Quarantine SG to isolate compromised instances"
  vpc_id      = var.vpc_id

  tags = {
    Name        = "${var.environment}-quarantine-isolation-sg"
    Environment = var.environment
  }
}

# 2. Amazon SNS Topic للإشعارات
resource "aws_sns_topic" "security_alerts" {
  name = "${var.environment}-security-incident-alerts"
}

resource "aws_sns_topic_subscription" "email_sub" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# 3. IAM Role & Policy لـ Lambda
resource "aws_iam_role" "quarantine_swap" {
  name = "${var.environment}_quarantine_swap_lambda_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_policy" "quarantine_swap" {
  name        = "${var.environment}_quarantine_swap_policy"
  description = "Policy to isolate EC2 instances and publish alerts to SNS"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:ModifyInstanceAttribute",
          "ec2:CreateTags"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = aws_sns_topic.security_alerts.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "quarantine_swap" {
  role       = aws_iam_role.quarantine_swap.name
  policy_arn = aws_iam_policy.quarantine_swap.arn
}

# 4. ضغط كود بايثون
data "archive_file" "quarantine_swap" {
  type        = "zip"
  source_file = "${path.module}/quarantine_swap.py"
  output_path = "${path.module}/quarantine_swap.zip"
}

# 5. دالة الـ Lambda
resource "aws_lambda_function" "quarantine_swap" {
  filename         = data.archive_file.quarantine_swap.output_path
  function_name    = "${var.environment}_quarantine_swap"
  role             = aws_iam_role.quarantine_swap.arn
  handler          = "quarantine_swap.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.quarantine_swap.output_base64sha256

  environment {
    variables = {
      ISOLATION_SECURITY_GROUP_ID = aws_security_group.isolation_sg.id
      SNS_TOPIC_ARN              = aws_sns_topic.security_alerts.arn
    }
  }
}

# 6. EventBridge Rule للاستماع للأحداث الأمنية
resource "aws_cloudwatch_event_rule" "quarantine_swap" {
  name        = "${var.environment}-quarantine-swap-trigger"
  description = "Route COMPROMISED_INSTANCE events to the quarantine-swap Lambda"

  event_pattern = jsonencode({
    source = ["custom.security.automation"]
    detail = { risk_type = ["COMPROMISED_INSTANCE"] }
  })
}

# 7. ربط EventBridge بـ Lambda
resource "aws_cloudwatch_event_target" "quarantine_swap" {
  rule      = aws_cloudwatch_event_rule.quarantine_swap.name
  target_id = "quarantine-swap-target"
  arn       = aws_lambda_function.quarantine_swap.arn
}

resource "aws_lambda_permission" "quarantine_swap" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.quarantine_swap.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.quarantine_swap.arn
}

# ---------------------------------------------------------------- renames (state-safe addresses)
moved {
  from = aws_iam_role.lambda_remediation_role
  to   = aws_iam_role.quarantine_swap
}

moved {
  from = aws_iam_policy.lambda_remediation_policy
  to   = aws_iam_policy.quarantine_swap
}

moved {
  from = aws_iam_role_policy_attachment.attach_remediation_policy
  to   = aws_iam_role_policy_attachment.quarantine_swap
}

moved {
  from = aws_lambda_function.remediation_lambda
  to   = aws_lambda_function.quarantine_swap
}

moved {
  from = aws_cloudwatch_event_rule.security_event_rule
  to   = aws_cloudwatch_event_rule.quarantine_swap
}

moved {
  from = aws_cloudwatch_event_target.lambda_target
  to   = aws_cloudwatch_event_target.quarantine_swap
}

moved {
  from = aws_lambda_permission.allow_eventbridge
  to   = aws_lambda_permission.quarantine_swap
}
