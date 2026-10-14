# Playbooks #2-#4 (Playbook #1 quarantine-swap lives in main.tf / lambda_function.py)
#   #2 asg-detach          -> asg_detach.py
#   #3 key-disable-revoke  -> key_disable_revoke.py
#   #4 ebs-snapshot        -> ebs_snapshot.py (+ evidence bucket)

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ---------------------------------------------------------------- evidence bucket (chain of custody)
resource "aws_s3_bucket" "evidence" {
  bucket              = "${var.environment}-security-evidence-${data.aws_caller_identity.current.account_id}"
  object_lock_enabled = true

  tags = {
    Name        = "${var.environment}-security-evidence"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_versioning" "evidence" {
  bucket = aws_s3_bucket.evidence.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "evidence" {
  bucket = aws_s3_bucket.evidence.id
  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = var.evidence_retention_days
    }
  }
  depends_on = [aws_s3_bucket_versioning.evidence]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "evidence" {
  bucket = aws_s3_bucket.evidence.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "evidence" {
  bucket                  = aws_s3_bucket.evidence.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "evidence_tls_only" {
  bucket = aws_s3_bucket.evidence.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.evidence.arn, "${aws_s3_bucket.evidence.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.evidence]
}

# ---------------------------------------------------------------- playbook definitions
locals {
  sns_statement = {
    Effect   = "Allow"
    Action   = ["sns:Publish"]
    Resource = aws_sns_topic.security_alerts.arn
  }
  logs_statement = {
    Effect   = "Allow"
    Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    Resource = "arn:aws:logs:*:*:*"
  }

  playbooks = {
    "asg-detach" = {
      source_file = "asg_detach.py"
      timeout     = 60
      memory      = 128
      env = {
        SNS_TOPIC_ARN = aws_sns_topic.security_alerts.arn
        ASG_ACTION    = var.asg_action
      }
      risk_types = ["COMPROMISED_INSTANCE", "UNHEALTHY_INSTANCE"]
      statements = [
        {
          Effect   = "Allow"
          Action   = ["autoscaling:DescribeAutoScalingInstances", "autoscaling:DetachInstances", "autoscaling:EnterStandby"]
          Resource = "*"
        },
        {
          Effect   = "Allow"
          Action   = ["ec2:CreateTags"]
          Resource = "*"
        },
      ]
    }

    "key-disable-revoke" = {
      source_file = "key_disable_revoke.py"
      timeout     = 60
      memory      = 128
      env = {
        SNS_TOPIC_ARN        = aws_sns_topic.security_alerts.arn
        PROTECTED_PRINCIPALS = join(",", var.protected_principals)
      }
      risk_types = ["COMPROMISED_CREDENTIALS", "CREDENTIAL_EXFILTRATION"]
      statements = [
        {
          Effect = "Allow"
          Action = [
            "iam:GetAccessKeyLastUsed",
            "iam:ListAccessKeys",
            "iam:UpdateAccessKey",
            "iam:PutUserPolicy",
            "iam:PutRolePolicy",
          ]
          Resource = "*"
        },
      ]
    }

    "ebs-snapshot" = {
      source_file = "ebs_snapshot.py"
      timeout     = 900
      memory      = 512
      env = {
        SNS_TOPIC_ARN   = aws_sns_topic.security_alerts.arn
        EVIDENCE_BUCKET = aws_s3_bucket.evidence.id
        MAX_HASH_BLOCKS = tostring(var.max_hash_blocks)
      }
      risk_types = ["COMPROMISED_INSTANCE", "FORENSIC_SNAPSHOT_REQUEST"]
      statements = [
        {
          Effect   = "Allow"
          Action   = ["ec2:DescribeInstances", "ec2:DescribeVolumes", "ec2:DescribeSnapshots", "ec2:CreateSnapshot", "ec2:CreateSnapshots", "ec2:CreateTags"]
          Resource = "*"
        },
        {
          Effect   = "Allow"
          Action   = ["ebs:ListSnapshotBlocks", "ebs:GetSnapshotBlock"]
          Resource = "arn:aws:ec2:${data.aws_region.current.name}::snapshot/*"
        },
        {
          # needed to read blocks of KMS-encrypted snapshots
          Effect   = "Allow"
          Action   = ["kms:Decrypt"]
          Resource = "*"
        },
        {
          Effect   = "Allow"
          Action   = ["s3:PutObject", "s3:GetObject"]
          Resource = "${aws_s3_bucket.evidence.arn}/custody/*"
        },
        {
          Effect   = "Allow"
          Action   = ["s3:ListBucket"]
          Resource = aws_s3_bucket.evidence.arn
        },
      ]
    }
  }
}

# ---------------------------------------------------------------- IAM (one least-privilege role per playbook)
resource "aws_iam_role" "playbook" {
  for_each = local.playbooks
  name     = "${var.environment}_${replace(each.key, "-", "_")}_lambda_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "playbook" {
  for_each = local.playbooks
  name     = "${var.environment}_${replace(each.key, "-", "_")}_policy"
  role     = aws_iam_role.playbook[each.key].id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = concat(each.value.statements, [local.sns_statement, local.logs_statement])
  })
}

# ---------------------------------------------------------------- Lambda functions
data "archive_file" "playbook" {
  for_each    = local.playbooks
  type        = "zip"
  source_file = "${path.module}/${each.value.source_file}"
  output_path = "${path.module}/${replace(each.key, "-", "_")}.zip"
}

resource "aws_lambda_function" "playbook" {
  for_each         = local.playbooks
  function_name    = "${var.environment}_${replace(each.key, "-", "_")}"
  filename         = data.archive_file.playbook[each.key].output_path
  source_code_hash = data.archive_file.playbook[each.key].output_base64sha256
  role             = aws_iam_role.playbook[each.key].arn
  handler          = "${trimsuffix(each.value.source_file, ".py")}.lambda_handler"
  runtime          = "python3.11"
  timeout          = each.value.timeout
  memory_size      = each.value.memory

  environment {
    variables = each.value.env
  }
}

# ---------------------------------------------------------------- EventBridge routing
resource "aws_cloudwatch_event_rule" "playbook" {
  for_each    = local.playbooks
  name        = "${var.environment}-${each.key}-trigger"
  description = "Route ${each.key} security events to its playbook Lambda"

  event_pattern = jsonencode({
    source = ["custom.security.automation"]
    detail = { risk_type = each.value.risk_types }
  })
}

resource "aws_cloudwatch_event_target" "playbook" {
  for_each  = local.playbooks
  rule      = aws_cloudwatch_event_rule.playbook[each.key].name
  target_id = "${each.key}-target"
  arn       = aws_lambda_function.playbook[each.key].arn
}

resource "aws_lambda_permission" "playbook" {
  for_each      = local.playbooks
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.playbook[each.key].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.playbook[each.key].arn
}

# Stage 2 of the EBS playbook: EC2 tells us when a snapshot finished -> hash it.
resource "aws_cloudwatch_event_rule" "ebs_snapshot_completed" {
  name        = "${var.environment}-ebs-snapshot-completed"
  description = "Hash forensic snapshots once EBS reports them completed"

  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["EBS Snapshot Notification"]
    detail        = { event = ["createSnapshot", "createSnapshots"], result = ["succeeded"] }
  })
}

resource "aws_cloudwatch_event_target" "ebs_snapshot_completed" {
  rule      = aws_cloudwatch_event_rule.ebs_snapshot_completed.name
  target_id = "ebs-snapshot-hash-target"
  arn       = aws_lambda_function.playbook["ebs-snapshot"].arn
}

resource "aws_lambda_permission" "ebs_snapshot_completed" {
  statement_id  = "AllowExecutionFromEbsSnapshotNotification"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.playbook["ebs-snapshot"].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ebs_snapshot_completed.arn
}
