data "aws_caller_identity" "current" {}

locals {


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

data "aws_kms_key" "ssm_default" {
  key_id = "alias/aws/ssm"
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
    sid       = "GetApmixApiKey"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.apmix_api_key.arn]
  }

  statement {
    sid       = "DecryptApmixApiKey"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_key.ssm_default.arn]
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

  statement {
    sid       = "ReadTriggerToken"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.jenkins_trigger_token.arn]
  }

  statement {
    sid       = "DecryptTriggerToken"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_key.ssm_default.arn]
  }

  statement {
    sid       = "MountJenkinsHome"
    actions   = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite", "elasticfilesystem:DescribeMountTargets"]
    resources = [aws_efs_file_system.jenkins_home.arn]
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
