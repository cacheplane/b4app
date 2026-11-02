output "state_bucket" {
  description = "Name of the Terraform state bucket."
  value       = aws_s3_bucket.state.bucket
}

output "state_kms_key_arn" {
  description = "KMS key that encrypts the state bucket."
  value       = aws_kms_key.state.arn
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "plan_role_arn" {
  description = "Role for pull request plans; record as AWS_ROLE_PLAN_<ENV>."
  value       = aws_iam_role.plan.arn
}

output "infra_role_arn" {
  description = "Role for Terraform applies; record as AWS_ROLE_INFRA_<ENV>."
  value       = aws_iam_role.infra.arn
}

output "deploy_role_arn" {
  description = "Role for image push and ECS deploys; record as AWS_ROLE_DEPLOY_<ENV>."
  value       = aws_iam_role.deploy.arn
}
