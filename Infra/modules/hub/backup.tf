resource "aws_backup_vault" "hub" {
  name        = local.name
  kms_key_arn = aws_kms_key.this.arn
}

# Cross-region copies land in a vault in the second provider's region. The
# account key is regional, so this vault uses the service default key.
resource "aws_backup_vault" "copy" {
  provider = aws.copy
  count    = var.backup_copy_region == null ? 0 : 1

  name = "${local.name}-copy"
}

resource "aws_backup_plan" "hub" {
  name = local.name

  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.hub.name
    schedule          = "cron(0 6 * * ? *)"

    lifecycle {
      delete_after = 35
    }

    dynamic "copy_action" {
      for_each = aws_backup_vault.copy
      content {
        destination_vault_arn = copy_action.value.arn

        lifecycle {
          delete_after = 35
        }
      }
    }
  }
}

resource "aws_iam_role" "backup" {
  name                 = "${local.name}-backup"
  permissions_boundary = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${local.name}-boundary"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "backup.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "backup" {
  for_each = toset([
    "AWSBackupServiceRolePolicyForBackup",
    "AWSBackupServiceRolePolicyForRestores",
  ])

  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/${each.key}"
}

resource "aws_backup_selection" "hub" {
  name         = local.name
  plan_id      = aws_backup_plan.hub.id
  iam_role_arn = aws_iam_role.backup.arn
  resources    = [aws_db_instance.hub.arn]
}
