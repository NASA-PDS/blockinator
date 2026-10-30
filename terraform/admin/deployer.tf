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

# The trust policy names the engineers' SSO role(s) by exact ARN rather than
# trusting the account root: within one account that lets them assume this role
# even if their permission set doesn't allow sts:AssumeRole. SSO role names
# carry a per-account random suffix, hence the lookup. If the permission set is
# ever re-provisioned (new role), re-apply this stage.
data "aws_iam_roles" "deployer_principals" {
  name_regex  = var.deployer_sso_role_name_regex
  path_prefix = "/aws-reserved/sso.amazonaws.com/"
}

data "aws_iam_policy_document" "deployer_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = sort(tolist(data.aws_iam_roles.deployer_principals.arns))
    }
  }
}

resource "aws_iam_role" "deployer" {
  name                 = "${local.name_prefix}-deployer"
  description          = "Assumed by platform engineers to deploy the blocklist Lambdas (iam:PassRole on their execution roles)"
  assume_role_policy   = data.aws_iam_policy_document.deployer_assume.json
  max_session_duration = 3600
  tags                 = local.tags

  lifecycle {
    precondition {
      condition     = length(data.aws_iam_roles.deployer_principals.arns) > 0
      error_message = "No SSO role matches deployer_sso_role_name_regex; platform engineers would be unable to assume the deployer role."
    }
  }
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
