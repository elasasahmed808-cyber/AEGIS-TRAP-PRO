# ---------------------------------------------------------------- canary key use alerts
# Fires immediately (via CloudTrail -> EventBridge) whenever any canary access
# key is used for any API call, independent of GuardDuty's detection delay.

resource "aws_sns_topic" "security_alerts" {
  name = "${var.name_prefix}-security-alerts"
}

resource "aws_sns_topic_subscription" "security_alerts_email" {
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = "baraamohamed2311@gmail.com"   # add this variable if it doesn't exist yet
}

resource "aws_cloudwatch_event_rule" "canary_key_used" {
  name        = "${var.name_prefix}-canary-key-used"
  description = "Alert the moment any canary IAM access key is used"

  event_pattern = jsonencode({
    source      = ["aws.sts", "aws.iam", "aws.s3", "aws.ec2"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      userIdentity = {
        accessKeyId = [for k in aws_iam_access_key.canary : k.id]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "canary_key_used" {
  rule      = aws_cloudwatch_event_rule.canary_key_used.name
  target_id = "canary-key-used-sns"
  arn       = aws_sns_topic.security_alerts.arn
}

resource "aws_sns_topic_policy" "allow_eventbridge_publish" {
  arn = aws_sns_topic.security_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEventBridgePublish"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.security_alerts.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = [
              aws_cloudwatch_event_rule.canary_key_used.arn,
              aws_cloudwatch_event_rule.decoy_s3_access.arn,
            ]
          }
        }
      }
    ]
  })
}

resource "aws_cloudwatch_event_rule" "decoy_s3_access" {
  name        = "${var.name_prefix}-decoy-s3-access"
  description = "Alert on any GetObject against the honeypot decoy bucket"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventName = ["GetObject"]
      requestParameters = {
        bucketName = ["proj-honeypot-decoy"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "decoy_s3_access" {
  rule      = aws_cloudwatch_event_rule.decoy_s3_access.name
  target_id = "decoy-s3-access-sns"
  arn       = aws_sns_topic.security_alerts.arn
}