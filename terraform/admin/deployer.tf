# Deployer role assumed by the PLATFORM stage to create and update the three
# Lambda functions.
#
# Creating a Lambda requires iam:PassRole on its execution role, which platform
# engineers' SSO roles lack, and SSO (AWSReservedSSO_*) roles cannot be granted
# extra permissions from inside the account. Instead, this role holds exactly
# that PassRole grant (and Lambda management for this component's functions),
# and platform engineers assume it. The platform stage uses it only for its
# aws_lambda_function resources; everything else runs as the engineer.
#
# ⚠️ Whoever can assume this role can run code as the updater role, i.e. can
# change this component's WAF IP sets. That is inherent to letting platform
# engineers deploy the updater Lambda.

data "aws_iam_policy_document" "deployer_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:PrincipalArn"
      values   = var.deployer_principal_arns
    }
  }
}

resource "aws_iam_role" "deployer" {
  name                 = "${local.name_prefix}-deployer"
  description          = "Assumed by platform engineers to deploy the blocklist Lambdas (iam:PassRole on their execution roles)"
  assume_role_policy   = data.aws_iam_policy_document.deployer_assume.json
  max_session_duration = 3600
  tags                 = local.tags
}

data "aws_iam_policy_document" "deployer" {
  statement {
    sid     = "PassLambdaExecutionRoles"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [
      aws_iam_role.updater.arn,
      aws_iam_role.sweeper.arn,
      aws_iam_role.audit.arn,
    ]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }

  statement {
    sid       = "ManageBlocklistLambdas"
    effect    = "Allow"
    actions   = ["lambda:*"]
    resources = ["arn:aws:lambda:${local.region}:${local.account_id}:function:${local.name_prefix}-*"]
  }
}

resource "aws_iam_role_policy" "deployer" {
  name   = "deployer"
  role   = aws_iam_role.deployer.id
  policy = data.aws_iam_policy_document.deployer.json
}
