data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  prefix     = "b4hub-${var.environment}"

  state_bucket = "${local.prefix}-tfstate"
  oidc_host    = "token.actions.githubusercontent.com"

  # The repository's immutable OIDC subject prefix (see variables.tf).
  repo_owner   = split("/", var.github_repository)[0]
  repo_name    = split("/", var.github_repository)[1]
  repo_subject = "repo:${local.repo_owner}@${var.github_owner_id}/${local.repo_name}@${var.github_repository_id}"

  # Test deploys from pushes to main; prod only from jobs that target the
  # `production` GitHub environment, so a push to main cannot assume it.
  protected_subject = {
    test = "${local.repo_subject}:ref:refs/heads/main"
    prod = "${local.repo_subject}:environment:production"
  }[var.environment]

  # Names are built here, not read from the resources, so the boundary can
  # name the roles it protects without a dependency cycle.
  role_names = {
    plan   = "${local.prefix}-plan"
    infra  = "${local.prefix}-infra"
    deploy = "${local.prefix}-deploy"
  }
  # A policy cannot reference itself, so the boundary's ARN is built from its name.
  boundary_arn = "arn:${local.partition}:iam::${local.account_id}:policy/${local.prefix}-boundary"
  role_arns    = { for k, n in local.role_names : k => "arn:${local.partition}:iam::${local.account_id}:role/${n}" }
}

resource "aws_kms_key" "state" {
  description             = "${local.state_bucket} state encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "state" {
  name          = "alias/${local.state_bucket}"
  target_key_id = aws_kms_key.state.key_id
}

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

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

  statement {
    sid       = "DenyWrongEncryption"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEqualsIfExists"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }

  # A request that names a KMS key must name the state key. Both conditions
  # must hold: Null = false limits the deny to requests that carry the header,
  # so a plain PutObject that relies on the bucket's default key is unaffected.
  statement {
    sid       = "DenyOtherKmsKeys"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = ["false"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [aws_kms_key.state.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}
