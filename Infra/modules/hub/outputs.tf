# Network
output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs, zone a then b."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs, zone a then b."
  value       = aws_subnet.private[*].id
}

output "sg_alb_id" {
  description = "Security group of the load balancer."
  value       = aws_security_group.alb.id
}

output "sg_task_id" {
  description = "Security group of the hub tasks."
  value       = aws_security_group.task.id
}

output "sg_db_id" {
  description = "Security group of the database."
  value       = aws_security_group.db.id
}

output "sg_admin_id" {
  description = "Security group of one-off admin tasks (migrations, seeding)."
  value       = aws_security_group.admin.id
}

# Edge
output "alb_dns_name" {
  description = "DNS name of the load balancer; point the hostname's CNAME here."
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  description = "Route 53 zone ID of the load balancer."
  value       = aws_lb.this.zone_id
}

# The first apply blocks on certificate validation until the owner adds these
# records at the DNS host. So read them first with
# `terraform apply -target=aws_acm_certificate.hub`, add them, then run the
# full apply.
output "acm_validation_records" {
  description = "DNS records to add at the DNS host to validate the certificate."
  value = [
    for o in aws_acm_certificate.hub.domain_validation_options : {
      name  = o.resource_record_name
      type  = o.resource_record_type
      value = o.resource_record_value
    }
  ]
}

output "target_group_arn" {
  description = "Target group the ECS service registers hub tasks in."
  value       = aws_lb_target_group.hub.arn
}

output "web_acl_arn" {
  description = "ARN of the WAF web ACL on the load balancer."
  value       = aws_wafv2_web_acl.hub.arn
}

# Data
output "db_endpoint" {
  description = "Database endpoint as host:port."
  value       = aws_db_instance.hub.endpoint
}

output "db_address" {
  description = "Database hostname."
  value       = aws_db_instance.hub.address
}

output "db_port" {
  description = "Database port."
  value       = aws_db_instance.hub.port
}

output "db_master_secret_arn" {
  description = "ARN of the RDS-managed master user secret."
  value       = aws_db_instance.hub.master_user_secret[0].secret_arn
}

output "secret_arns" {
  description = "Secrets Manager ARNs keyed by short name (database-url, secret-key, ...)."
  value       = { for k, s in aws_secretsmanager_secret.this : k => s.arn }
}

output "kms_key_arn" {
  description = "ARN of the customer-managed key for the account's data."
  value       = aws_kms_key.this.arn
}

output "backup_vault_arn" {
  description = "ARN of the primary backup vault."
  value       = aws_backup_vault.hub.arn
}
