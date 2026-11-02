# Tests apply against a mocked AWS provider; nothing here needs credentials.
# The policy JSON of a mocked data source is a placeholder, so the assertions
# read the aws_iam_policy_document arguments (conditions, actions) instead.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/b4hub-mock-boundary"
    }
  }

  mock_resource "aws_iam_openid_connect_provider" {
    defaults = {
      arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock"
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:us-east-2:123456789012:key/00000000-0000-0000-0000-000000000000"
    }
  }

  mock_resource "aws_s3_bucket" {
    defaults = {
      arn = "arn:aws:s3:::mock-bucket"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

run "prod_trust_is_environment_scoped" {
  command = apply

  variables {
    environment = "prod"
  }

  assert {
    condition = (
      one([for c in data.aws_iam_policy_document.infra_trust.statement[0].condition : c if c.variable == "token.actions.githubusercontent.com:sub"]).test == "StringEquals"
      && toset(one([for c in data.aws_iam_policy_document.infra_trust.statement[0].condition : c if c.variable == "token.actions.githubusercontent.com:sub"]).values) == toset(["repo:cacheplane/b4app:environment:production"])
    )
    error_message = "prod infra role must trust only the production GitHub environment"
  }

  assert {
    condition = (
      one([for c in data.aws_iam_policy_document.deploy_trust.statement[0].condition : c if c.variable == "token.actions.githubusercontent.com:sub"]).test == "StringEquals"
      && toset(one([for c in data.aws_iam_policy_document.deploy_trust.statement[0].condition : c if c.variable == "token.actions.githubusercontent.com:sub"]).values) == toset(["repo:cacheplane/b4app:environment:production"])
    )
    error_message = "prod deploy role must trust only the production GitHub environment"
  }

  assert {
    condition     = aws_iam_role.infra.assume_role_policy == data.aws_iam_policy_document.infra_trust.json
    error_message = "infra role must use the infra trust document"
  }

  assert {
    condition     = output.state_bucket == "b4hub-prod-tfstate"
    error_message = "state bucket name must be b4hub-<env>-tfstate"
  }
}

run "test_trust_is_main_branch" {
  command = apply

  variables {
    environment = "test"
  }

  assert {
    condition = (
      toset(one([for c in data.aws_iam_policy_document.infra_trust.statement[0].condition : c if c.variable == "token.actions.githubusercontent.com:sub"]).values) == toset(["repo:cacheplane/b4app:ref:refs/heads/main"])
      && toset(one([for c in data.aws_iam_policy_document.deploy_trust.statement[0].condition : c if c.variable == "token.actions.githubusercontent.com:sub"]).values) == toset(["repo:cacheplane/b4app:ref:refs/heads/main"])
    )
    error_message = "test infra and deploy roles must trust only pushes to main"
  }

  assert {
    condition = (
      toset(one([for c in data.aws_iam_policy_document.infra_trust.statement[0].condition : c if c.variable == "token.actions.githubusercontent.com:aud"]).values) == toset(["sts.amazonaws.com"])
      && toset(data.aws_iam_policy_document.infra_trust.statement[0].actions) == toset(["sts:AssumeRoleWithWebIdentity"])
    )
    error_message = "trust must require the sts.amazonaws.com audience via web identity"
  }
}

run "plan_trust_allows_any_ref_in_repository" {
  command = apply

  variables {
    environment = "test"
  }

  assert {
    condition = (
      one([for c in data.aws_iam_policy_document.plan_trust.statement[0].condition : c if c.variable == "token.actions.githubusercontent.com:sub"]).test == "StringLike"
      && toset(one([for c in data.aws_iam_policy_document.plan_trust.statement[0].condition : c if c.variable == "token.actions.githubusercontent.com:sub"]).values) == toset(["repo:cacheplane/b4app:*"])
    )
    error_message = "plan role must trust any ref in cacheplane/b4app via StringLike"
  }
}

run "deploy_role_has_no_admin" {
  command = apply

  variables {
    environment = "test"
  }

  assert {
    condition     = aws_iam_role_policy_attachment.infra_admin.policy_arn == "arn:aws:iam::aws:policy/AdministratorAccess" && aws_iam_role_policy_attachment.infra_admin.role == "b4hub-test-infra"
    error_message = "only the infra role carries AdministratorAccess"
  }

  assert {
    condition     = aws_iam_role_policy_attachment.plan_read_only.role == "b4hub-test-plan" && aws_iam_role_policy_attachment.plan_read_only.policy_arn != "arn:aws:iam::aws:policy/AdministratorAccess"
    error_message = "plan role is read-only"
  }

  assert {
    condition = alltrue([
      for a in flatten([for s in data.aws_iam_policy_document.deploy.statement : tolist(s.actions)]) :
      a != "*" && !endswith(a, ":*") && (!startswith(a, "iam:") || a == "iam:PassRole")
    ])
    error_message = "deploy policy must have no wildcard actions and no IAM action besides PassRole"
  }

  assert {
    condition     = alltrue([for s in data.aws_iam_policy_document.deploy.statement : coalesce(s.effect, "Allow") == "Allow"])
    error_message = "deploy policy only allows"
  }
}

run "deploy_pass_role_is_limited_to_task_roles" {
  command = apply

  variables {
    environment = "prod"
  }

  assert {
    condition = one([
      for s in data.aws_iam_policy_document.deploy.statement : s if contains(tolist(s.actions), "iam:PassRole")
      ]).resources == toset([
      "arn:aws:iam::123456789012:role/b4hub-prod-task-exec",
      "arn:aws:iam::123456789012:role/b4hub-prod-task",
    ])
    error_message = "PassRole is limited to the two task roles"
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.deploy.statement :
      !contains(s.resources, "*") || length(setsubtract(s.actions, ["ecr:GetAuthorizationToken", "ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"])) == 0
    ])
    error_message = "only actions that AWS cannot scope to a resource may use Resource *"
  }
}

run "boundary_denies_iam_users" {
  command = apply

  variables {
    environment = "test"
  }

  assert {
    condition = (
      aws_iam_policy.boundary.name == "b4hub-test-boundary"
      && aws_iam_role.infra.permissions_boundary == aws_iam_policy.boundary.arn
    )
    error_message = "infra role must carry the b4hub-<env>-boundary permissions boundary"
  }

  assert {
    condition = (
      one([for s in data.aws_iam_policy_document.boundary.statement : s if s.sid == "DenyIdentityEscalation"]).effect == "Deny"
      && setintersection(
        one([for s in data.aws_iam_policy_document.boundary.statement : s if s.sid == "DenyIdentityEscalation"]).actions,
        ["iam:CreateUser", "iam:CreateAccessKey", "iam:CreateLoginProfile", "organizations:*", "account:*"]
      ) == toset(["iam:CreateUser", "iam:CreateAccessKey", "iam:CreateLoginProfile", "organizations:*", "account:*"])
    )
    error_message = "boundary must deny user, access key, login profile, organizations, and account actions"
  }
}

run "state_bucket_is_private_and_encrypted" {
  command = apply

  variables {
    environment = "test"
  }

  assert {
    condition = (
      aws_s3_bucket_public_access_block.state.block_public_acls
      && aws_s3_bucket_public_access_block.state.block_public_policy
      && aws_s3_bucket_public_access_block.state.ignore_public_acls
      && aws_s3_bucket_public_access_block.state.restrict_public_buckets
    )
    error_message = "state bucket must block all public access"
  }

  assert {
    condition     = one(aws_s3_bucket_versioning.state.versioning_configuration).status == "Enabled"
    error_message = "state bucket must be versioned"
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.state.rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms"
    error_message = "state bucket must default to SSE-KMS"
  }
}
