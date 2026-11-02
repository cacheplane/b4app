locals {
  oidc_sub = "${local.oidc_host}:sub"
  oidc_aud = "${local.oidc_host}:aud"
}

# ---- Trust documents ----

data "aws_iam_policy_document" "plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = local.oidc_aud
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = local.oidc_sub
      values   = ["repo:${var.github_repository}:*"]
    }
  }
}

data "aws_iam_policy_document" "infra_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = local.oidc_aud
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = local.oidc_sub
      values   = [local.protected_subject]
    }
  }
}

data "aws_iam_policy_document" "deploy_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = local.oidc_aud
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = local.oidc_sub
      values   = [local.protected_subject]
    }
  }
}

# ---- Permissions boundary for the infra role ----

data "aws_iam_policy_document" "boundary" {
  statement {
    sid       = "AllowEverythingElse"
    effect    = "Allow"
    actions   = ["*"]
    resources = ["*"]
  }

  statement {
    sid    = "DenyIdentityEscalation"
    effect = "Deny"
    actions = [
      "iam:CreateUser",
      "iam:CreateAccessKey",
      "iam:CreateLoginProfile",
      "organizations:*",
      "account:*",
    ]
    resources = ["*"]
  }

  # Applies cannot loosen the guard rails or rewrite the three CI roles.
  statement {
    sid    = "DenyTamperingWithBootstrap"
    effect = "Deny"
    actions = [
      "iam:AttachRolePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
      "iam:DeleteRole",
      "iam:DeleteRolePermissionsBoundary",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePermissionsBoundary",
      "iam:PutRolePolicy",
      "iam:SetDefaultPolicyVersion",
      "iam:UpdateAssumeRolePolicy",
    ]
    resources = concat(
      values(local.role_arns),
      ["arn:${local.partition}:iam::${local.account_id}:policy/${local.prefix}-boundary"],
    )
  }
}

resource "aws_iam_policy" "boundary" {
  name        = "${local.prefix}-boundary"
  description = "Permissions boundary for the ${var.environment} infra role."
  policy      = data.aws_iam_policy_document.boundary.json
}

# ---- Plan role: read-only ----

resource "aws_iam_role" "plan" {
  name                 = local.role_names.plan
  description          = "Pull request terraform plan for ${var.environment}."
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_read_only" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

# A plan reads state and, with use_lockfile, writes only the lock object.
data "aws_iam_policy_document" "plan" {
  statement {
    sid       = "ReadState"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }

  statement {
    sid       = "ListState"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid       = "WriteStateLock"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*.tflock"]
  }

  statement {
    sid       = "StateKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.state.arn]
  }
}

resource "aws_iam_role_policy" "plan" {
  name   = "state-access"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan.json
}

# ---- Infra role: administrator, capped by the boundary ----

resource "aws_iam_role" "infra" {
  name                 = local.role_names.infra
  description          = "Terraform apply for ${var.environment}."
  assume_role_policy   = data.aws_iam_policy_document.infra_trust.json
  permissions_boundary = aws_iam_policy.boundary.arn
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "infra_admin" {
  role       = aws_iam_role.infra.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AdministratorAccess"
}

# ---- Deploy role: image push and ECS rollout only ----

locals {
  ecs_arn = "arn:${local.partition}:ecs:${var.region}:${local.account_id}"
}

data "aws_iam_policy_document" "deploy" {
  # AWS does not support resource-level permissions for these two actions.
  statement {
    sid       = "TaskDefinitions"
    actions   = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"]
    resources = ["*"]
  }

  statement {
    sid       = "RunTaskInCluster"
    actions   = ["ecs:RunTask"]
    resources = ["${local.ecs_arn}:task-definition/${local.prefix}*:*"]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = ["${local.ecs_arn}:cluster/${local.prefix}"]
    }
  }

  statement {
    sid       = "DescribeTasksInCluster"
    actions   = ["ecs:DescribeTasks"]
    resources = ["${local.ecs_arn}:task/${local.prefix}/*"]
  }

  statement {
    sid       = "UpdateServicesInCluster"
    actions   = ["ecs:UpdateService", "ecs:DescribeServices"]
    resources = ["${local.ecs_arn}:service/${local.prefix}/*"]
  }

  statement {
    sid     = "PassTaskRoles"
    actions = ["iam:PassRole"]
    resources = [
      "arn:${local.partition}:iam::${local.account_id}:role/${local.prefix}-task-exec",
      "arn:${local.partition}:iam::${local.account_id}:role/${local.prefix}-task",
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = ["arn:${local.partition}:ecr:${var.region}:${local.account_id}:repository/b4hub"]
  }

  statement {
    sid       = "ReadTaskLogs"
    actions   = ["logs:GetLogEvents"]
    resources = ["arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:/b4hub/${var.environment}/*"]
  }
}

resource "aws_iam_role" "deploy" {
  name                 = local.role_names.deploy
  description          = "Image push and ECS deploy for ${var.environment}."
  assume_role_policy   = data.aws_iam_policy_document.deploy_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}
