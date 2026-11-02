locals {
  secret_names = [
    "database-admin-url",
    "database-url",
    "secret-key",
    "apple-team-id",
    "apple-key-id",
    "apple-private-key",
  ]
}

# The secrets are created empty. There is deliberately no
# aws_secretsmanager_secret_version here: values are set by the owner with the
# CLI (aws secretsmanager put-secret-value), so they never enter Terraform
# state. The ECS task definition references them by ARN.
resource "aws_secretsmanager_secret" "this" {
  for_each = toset(local.secret_names)

  name                    = "b4hub/${each.key}"
  kms_key_id              = aws_kms_key.this.arn
  recovery_window_in_days = 7

  tags = { Name = "b4hub/${each.key}" }
}
