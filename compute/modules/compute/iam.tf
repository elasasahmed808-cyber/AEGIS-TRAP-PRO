data "aws_caller_identity" "current" {}

locals {
  # "us.anthropic.claude-haiku-4-5-..." -> "anthropic.claude-haiku-4-5-..."
  # Foundation-model ARNs use the base ID, never the geo prefix.
  base_model_id = replace(var.bedrock_model_id, "/^(us|eu|apac|jp|au|global)\\./", "")

  # Cross-region inference profiles need permission on BOTH the profile ARN and
  # the underlying foundation model in every region the profile can route to.
  model_arns = length(var.bedrock_model_arns) > 0 ? var.bedrock_model_arns : concat(
    [for r in var.bedrock_profile_regions : "arn:aws:bedrock:${r}::foundation-model/${local.base_model_id}"],
    ["arn:aws:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:inference-profile/${var.bedrock_model_id}"]
  )

  documents_arn = "arn:aws:s3:::${var.documents_bucket_name}"
  build_arn     = "arn:aws:s3:::${var.build_artifacts_bucket_name}"
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# ===================== DocuMind app role =====================
resource "aws_iam_role" "app" {
  name               = "${var.name_prefix}-documind-app"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "app_ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_role_policy_attachment" "app_cw" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

data "aws_iam_policy_document" "app" {
  statement {
    sid       = "PutSummaries"
    actions   = ["s3:PutObject"]
    resources = ["${local.documents_arn}/${var.summaries_prefix}*"]
  }
  statement {
    sid       = "InvokeOneModel"
    actions   = ["bedrock:InvokeModel"]
    resources = local.model_arns
  }
  statement {
    sid       = "ApplyOurGuardrail"
    actions   = ["bedrock:ApplyGuardrail"]
    resources = [var.guardrail_arn]
  }
  statement {
    sid       = "PullBuildArtifact"
    actions   = ["s3:GetObject"]
    resources = ["${local.build_arn}/${var.artifact_prefix}*"]
  }

  statement {
    sid       = "TempMarketplaceFirstUse"
    actions   = ["aws-marketplace:ViewSubscriptions", "aws-marketplace:Subscribe"]
    resources = ["*"]   # these actions don't support resource-level scoping
  }
}

resource "aws_iam_role_policy" "app" {
  name   = "documind-app"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app.json
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.name_prefix}-documind-app"
  role = aws_iam_role.app.name
}

# ===================== Jenkins role =====================
resource "aws_iam_role" "jenkins" {
  name               = "${var.name_prefix}-jenkins"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "jenkins_ssm" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_role_policy_attachment" "jenkins_cw" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

data "aws_iam_policy_document" "jenkins" {
  statement {
    sid     = "SendCommandToAppInstances"
    actions = ["ssm:SendCommand"]
    resources = [
      "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Role"
      values   = ["documind-app"]
    }
  }
  statement {
    sid       = "SendCommandDocument"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:${var.region}::document/AWS-RunShellScript"]
  }
  statement {
    sid       = "CommandStatus"
    actions   = ["ssm:GetCommandInvocation", "ssm:ListCommands", "ssm:ListCommandInvocations", "ssm:DescribeInstanceInformation", "ec2:DescribeInstances"]
    resources = ["*"]
  }
  statement {
    sid       = "BuildArtifactsRW"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:GetObjectVersion"]
    resources = [local.build_arn, "${local.build_arn}/*"]
  }
}

resource "aws_iam_role_policy" "jenkins" {
  name   = "jenkins"
  role   = aws_iam_role.jenkins.id
  policy = data.aws_iam_policy_document.jenkins.json
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.name_prefix}-jenkins"
  role = aws_iam_role.jenkins.name
}

# ===================== Canary users (NO permissions) =====================

resource "aws_iam_access_key" "canary" {
  for_each = var.canary_users
  user     = each.value.name
}
