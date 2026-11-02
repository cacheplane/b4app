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
