# Tests apply against a mocked AWS provider; nothing here needs credentials.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111111111111"
    }
  }

  mock_data "aws_elb_service_account" {
    defaults = {
      arn = "arn:aws:iam::033677994240:root"
    }
  }

  mock_resource "aws_lb" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-2:111111111111:loadbalancer/app/b4hub-test/0123456789abcdef"
    }
  }

  mock_resource "aws_lb_target_group" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-2:111111111111:targetgroup/b4hub-test-hub/0123456789abcdef"
    }
  }

  mock_resource "aws_acm_certificate" {
    defaults = {
      arn = "arn:aws:acm:us-east-2:111111111111:certificate/00000000-0000-0000-0000-000000000000"
    }
  }

  mock_resource "aws_wafv2_web_acl" {
    defaults = {
      arn = "arn:aws:wafv2:us-east-2:111111111111:regional/webacl/b4hub-test-web-acl/00000000-0000-0000-0000-000000000000"
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:us-east-2:111111111111:key/00000000-0000-0000-0000-000000000000"
    }
  }

  mock_resource "aws_db_instance" {
    defaults = {
      arn = "arn:aws:rds:us-east-2:111111111111:db:b4hub-test"
      master_user_secret = [{
        secret_arn = "arn:aws:secretsmanager:us-east-2:111111111111:secret:rds!db-00000000-0000-0000-0000-000000000000-AbCdEf"
      }]
    }
  }

  mock_resource "aws_backup_vault" {
    defaults = {
      arn = "arn:aws:backup:us-east-2:111111111111:backup-vault:b4hub-test"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111111111111:role/b4hub-test-backup"
    }
  }

  mock_resource "aws_ecr_repository" {
    defaults = {
      arn            = "arn:aws:ecr:us-east-2:111111111111:repository/b4hub"
      repository_url = "111111111111.dkr.ecr.us-east-2.amazonaws.com/b4hub"
    }
  }

  mock_resource "aws_ecs_cluster" {
    defaults = {
      arn = "arn:aws:ecs:us-east-2:111111111111:cluster/b4hub-test"
    }
  }

  mock_resource "aws_ecs_task_definition" {
    defaults = {
      arn = "arn:aws:ecs:us-east-2:111111111111:task-definition/b4hub-test-hub:1"
    }
  }
}

mock_provider "aws" {
  alias = "copy"

  mock_resource "aws_backup_vault" {
    defaults = {
      arn = "arn:aws:backup:us-west-2:111111111111:backup-vault:b4hub-test-copy"
    }
  }
}

variables {
  environment = "test"
  alarm_email = "ops@example.com"
}

run "no_secret_values_in_terraform" {
  command = apply

  assert {
    condition     = length(aws_secretsmanager_secret.this) == 6
    error_message = "six secrets exist"
  }

  assert {
    condition     = toset(keys(aws_secretsmanager_secret.this)) == toset(["database-admin-url", "database-url", "secret-key", "apple-team-id", "apple-key-id", "apple-private-key"])
    error_message = "secrets are keyed by short name"
  }

  assert {
    condition     = alltrue([for k, s in aws_secretsmanager_secret.this : s.name == "b4hub/${k}" && s.recovery_window_in_days == 7])
    error_message = "secret names are b4hub/<name> with a 7-day recovery window"
  }

  assert {
    condition     = alltrue([for k, s in aws_secretsmanager_secret.this : s.kms_key_id == aws_kms_key.this.arn])
    error_message = "every secret is encrypted with the account key"
  }

  # Values are set by the owner with the CLI. A version resource anywhere in
  # the module would put a value in state, so scan the module's own files.
  assert {
    condition     = length(regexall("resource\\s+\"aws_secretsmanager_secret_version\"", join("\n", [for f in fileset(path.module, "*.tf") : file("${path.module}/${f}")]))) == 0
    error_message = "the module declares no aws_secretsmanager_secret_version"
  }
}

run "rds_private_encrypted" {
  command = apply

  assert {
    condition     = aws_db_instance.hub.publicly_accessible == false
    error_message = "the database is not public"
  }

  assert {
    condition     = aws_db_instance.hub.storage_encrypted == true && aws_db_instance.hub.kms_key_id == aws_kms_key.this.arn
    error_message = "storage is encrypted with the account key"
  }

  assert {
    condition     = aws_db_instance.hub.manage_master_user_password == true && aws_db_instance.hub.master_user_secret_kms_key_id == aws_kms_key.this.arn
    error_message = "RDS manages the master password under the account key"
  }

  assert {
    condition     = aws_db_instance.hub.engine == "postgres" && aws_db_instance.hub.engine_version == "17" && aws_db_instance.hub.auto_minor_version_upgrade == true
    error_message = "PostgreSQL 17 with automatic minor upgrades"
  }

  assert {
    condition     = aws_db_instance.hub.allocated_storage == 20 && aws_db_instance.hub.max_allocated_storage == 100 && aws_db_instance.hub.storage_type == "gp3"
    error_message = "gp3, 20 GiB growing to 100"
  }

  assert {
    condition     = aws_db_instance.hub.vpc_security_group_ids == toset([aws_security_group.db.id])
    error_message = "only the db security group is attached"
  }

  assert {
    condition     = aws_db_instance.hub.deletion_protection == false && aws_db_instance.hub.skip_final_snapshot == true
    error_message = "test environments are disposable"
  }

  assert {
    condition     = aws_kms_key.this.enable_key_rotation == true && aws_kms_key.this.deletion_window_in_days == 30
    error_message = "the account key rotates and has a 30-day deletion window"
  }
}

run "prod_deletion_protection" {
  command = apply

  variables {
    environment = "prod"
  }

  assert {
    condition     = aws_db_instance.hub.deletion_protection == true
    error_message = "prod is deletion protected"
  }

  assert {
    condition     = aws_db_instance.hub.skip_final_snapshot == false && aws_db_instance.hub.final_snapshot_identifier == "b4hub-prod-final"
    error_message = "prod takes a final snapshot"
  }
}

run "copy_action_only_with_region" {
  command = apply

  assert {
    condition     = length(one(aws_backup_plan.hub.rule).copy_action) == 0 && length(aws_backup_vault.copy) == 0
    error_message = "no copy action or copy vault by default"
  }

  assert {
    condition     = one(aws_backup_plan.hub.rule).schedule == "cron(0 6 * * ? *)" && one(one(aws_backup_plan.hub.rule).lifecycle).delete_after == 35
    error_message = "daily at 06:00 UTC, kept 35 days"
  }
}

run "copy_action_with_region" {
  command = apply

  variables {
    backup_copy_region = "us-west-2"
  }

  assert {
    condition     = length(one(aws_backup_plan.hub.rule).copy_action) == 1 && length(aws_backup_vault.copy) == 1
    error_message = "one copy action and a copy vault with a region"
  }
}

run "backup_role_is_bounded" {
  command = apply

  assert {
    condition     = aws_iam_role.backup.permissions_boundary == "arn:aws:iam::111111111111:policy/b4hub-test-boundary"
    error_message = "the backup role carries the permissions boundary"
  }

  assert {
    condition     = jsondecode(aws_iam_role.backup.assume_role_policy).Statement[0].Principal.Service == "backup.amazonaws.com"
    error_message = "the role trusts AWS Backup"
  }

  assert {
    condition     = length(aws_backup_selection.hub.resources) == 1
    error_message = "the selection targets the database"
  }
}
