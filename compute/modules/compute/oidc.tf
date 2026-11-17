resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:elasasahmed808-cyber/AEGIS-TRAP-PRO.git:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "gha_read_lb" {
  name               = "gha-read-lb"
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

resource "aws_iam_role_policy" "describe_lb" {
  name = "describe-lb"
  role = aws_iam_role.gha_read_lb.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["elasticloadbalancing:DescribeLoadBalancers"]
      Resource = "*"
    }]
  })
}