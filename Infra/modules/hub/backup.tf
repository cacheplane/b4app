resource "aws_backup_vault" "hub" {
  name        = local.name
  kms_key_arn = aws_kms_key.this.arn
}

# Cross-region copies land in a vault in the second provider's region. The
# account key is regional, so the copy region gets its own customer managed
# key: a snapshot under the service default key can be restored only in that
# region and account, while one under this key can be copied back to the hub's
# region or shared, which the restore drill's comparison (runbook 8 B.3) needs.
resource "aws_kms_key" "copy" {
  provider = aws.copy
  count    = var.backup_copy_region == null ? 0 : 1

  description             = "${local.name} backup copies"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "copy" {
  provider = aws.copy
  count    = var.backup_copy_region == null ? 0 : 1

  name          = "alias/${local.name}-copy"
  target_key_id = aws_kms_key.copy[0].key_id
}

resource "aws_backup_vault" "copy" {
  provider = aws.copy
  count    = var.backup_copy_region == null ? 0 : 1

  name        = "${local.name}-copy"
  kms_key_arn = aws_kms_key.copy[0].arn

  # The key cannot change on a vault, so a key change replaces it. The copies
  # here are secondary (the source vault keeps its own for 35 days), so the
  # replacement may remove them; without this the destroy fails while any
  # recovery point remains.
  force_destroy = true
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
      # Only AWS Backup acting for this account may assume the role (confused deputy).
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
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

  # The selection is validated against the role's permissions when it is
  # created, so the managed policies must be attached first.
  depends_on = [aws_iam_role_policy_attachment.backup]
}
