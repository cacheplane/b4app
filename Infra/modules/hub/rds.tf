# One customer-managed key for the account's data: database storage, the
# managed master secret, every Secrets Manager secret, and the backup vault.
# The default key policy delegates to IAM in this account.
resource "aws_kms_key" "this" {
  description             = "${local.name} data: database, secrets, backups"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "this" {
  name          = "alias/${local.name}-data"
  target_key_id = aws_kms_key.this.key_id
}

resource "aws_db_subnet_group" "hub" {
  name       = local.name
  subnet_ids = aws_subnet.private[*].id

  tags = { Name = local.name }
}

resource "aws_db_instance" "hub" {
  identifier = local.name

  engine                     = "postgres"
  engine_version             = "17" # major only: minor upgrades are automatic
  auto_minor_version_upgrade = true
  instance_class             = var.db_instance_class
  multi_az                   = var.db_multi_az

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.this.arn

  username                      = "b4hub_master"
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.this.arn
  # The b4hub database is created later by the admin task.
  db_name = null
  port    = 5432

  db_subnet_group_name   = aws_db_subnet_group.hub.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  ca_cert_identifier     = "rds-ca-rsa2048-g1"

  backup_retention_period = var.db_backup_retention_days
  backup_window           = "05:00-06:00"
  maintenance_window      = "sun:06:30-sun:07:30"
  copy_tags_to_snapshot   = true

  deletion_protection       = var.environment == "prod"
  skip_final_snapshot       = var.environment != "prod"
  final_snapshot_identifier = var.environment == "prod" ? "${local.name}-final" : null
  apply_immediately         = false

  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  performance_insights_kms_key_id       = aws_kms_key.this.arn
  monitoring_interval                   = 0

  tags = { Name = local.name }
}
