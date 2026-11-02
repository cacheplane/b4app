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
