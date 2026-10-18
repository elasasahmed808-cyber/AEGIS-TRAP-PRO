data "aws_caller_identity" "current" {}

# ---------------- Guardrail ----------------
resource "aws_bedrock_guardrail" "this" {
  count                     = var.create_guardrail ? 1 : 0
  name                      = "${var.name_prefix}-documind-guardrail"
  description               = "DocuMind guardrail"
  blocked_input_messaging   = "Your request was blocked by policy."
  blocked_outputs_messaging = "The response was blocked by policy."

  content_policy_config {
    filters_config {
      type            = "HATE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "VIOLENCE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "INSULTS"
      input_strength  = "MEDIUM"
      output_strength = "MEDIUM"
    }
    filters_config {
      type            = "PROMPT_ATTACK"
      input_strength  = "HIGH"
      output_strength = "NONE"
    }
  }

  sensitive_information_policy_config {
    pii_entities_config {
      type   = "AWS_ACCESS_KEY"
      action = "BLOCK"
    }
    pii_entities_config {
      type   = "AWS_SECRET_KEY"
      action = "BLOCK"
    }
  }
}

resource "aws_bedrock_guardrail_version" "this" {
  count         = var.create_guardrail ? 1 : 0
  guardrail_arn = aws_bedrock_guardrail.this[0].guardrail_arn
  description   = "managed by terraform"
}

locals {
  guardrail_id      = var.create_guardrail ? aws_bedrock_guardrail.this[0].guardrail_id : var.existing_guardrail_id
  guardrail_arn     = var.create_guardrail ? aws_bedrock_guardrail.this[0].guardrail_arn : "arn:aws:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:guardrail/${var.existing_guardrail_id}"
  guardrail_version = var.create_guardrail ? aws_bedrock_guardrail_version.this[0].version : var.existing_guardrail_version
}

# ---------------- Invocation logs bucket (owner: Ahmed / M3) ----------------
resource "aws_s3_bucket" "logs" {
  bucket = var.logs_bucket_name
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id
  versioning_configuration { status = "Enabled" }
}

# SSE-S3 on purpose: Bedrock log delivery to a CMK bucket needs extra key-policy work.
resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

data "aws_iam_policy_document" "logs_bucket" {
  statement {
    sid       = "AmazonBedrockLogsWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/bedrock/AWSLogs/${data.aws_caller_identity.current.account_id}/BedrockModelInvocationLogs/*"]
    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.logs.arn, "${aws_s3_bucket.logs.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "logs" {
  bucket     = aws_s3_bucket.logs.id
  policy     = data.aws_iam_policy_document.logs_bucket.json
  depends_on = [aws_s3_bucket_public_access_block.logs]
}

# ---------------- CloudWatch Logs + delivery role ----------------
resource "aws_cloudwatch_log_group" "bedrock" {
  name              = "/aws/bedrock/${var.name_prefix}-invocations"
  retention_in_days = 90
}

data "aws_iam_policy_document" "bedrock_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

resource "aws_iam_role" "bedrock_logging" {
  name               = "${var.name_prefix}-bedrock-logging"
  assume_role_policy = data.aws_iam_policy_document.bedrock_trust.json
}

data "aws_iam_policy_document" "bedrock_logging" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.bedrock.arn}:*"]
  }
}

resource "aws_iam_role_policy" "bedrock_logging" {
  role   = aws_iam_role.bedrock_logging.id
  policy = data.aws_iam_policy_document.bedrock_logging.json
}

resource "aws_bedrock_model_invocation_logging_configuration" "this" {
  logging_config {
    embedding_data_delivery_enabled = true
    image_data_delivery_enabled     = true
    text_data_delivery_enabled      = true

    cloudwatch_config {
      log_group_name = aws_cloudwatch_log_group.bedrock.name
      role_arn       = aws_iam_role.bedrock_logging.arn
    }
    s3_config {
      bucket_name = aws_s3_bucket.logs.id
      key_prefix  = "bedrock"
    }
  }
  depends_on = [aws_s3_bucket_policy.logs, aws_iam_role_policy.bedrock_logging]
}
