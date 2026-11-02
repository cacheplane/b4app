provider "aws" {
  region = "us-east-2"

  default_tags {
    tags = {
      Project     = "b4hub"
      Environment = "test"
      ManagedBy   = "terraform"
    }
  }
}

provider "aws" {
  alias  = "copy"
  region = "us-east-2"

  default_tags {
    tags = {
      Project     = "b4hub"
      Environment = "test"
      ManagedBy   = "terraform"
    }
  }
}

variable "alarm_email" {
  description = "Email address for alarm and budget notifications. CI passes it as TF_VAR_alarm_email from the repository variable B4HUB_ALARM_EMAIL."
  type        = string
}

module "hub" {
  source = "../../modules/hub"

  providers = {
    aws      = aws
    aws.copy = aws.copy
  }

  environment              = "test"
  region                   = "us-east-2"
  hostname                 = "hub.test.b4.run"
  db_backup_retention_days = 7
  backup_copy_region       = null
  monthly_budget_usd       = 70
  alarm_email              = var.alarm_email

  # Created with no tasks so the first apply does not wait on an image that is
  # not pushed yet. After the first deploy succeeds (Infra/README.md, "First
  # deploy"), change this to 1 and apply again; that also enables the
  # running-tasks alarm.
  desired_count = 0
}

output "alb_dns_name" {
  description = "Load balancer DNS name; the hostname's CNAME points here."
  value       = module.hub.alb_dns_name
}

output "acm_validation_records" {
  description = "DNS records to add at the DNS host to validate the certificate."
  value       = module.hub.acm_validation_records
}

output "db_master_secret_arn" {
  description = "ARN of the RDS-managed master user secret."
  value       = module.hub.db_master_secret_arn
}

output "secret_arns" {
  description = "Secrets Manager ARNs keyed by short name."
  value       = module.hub.secret_arns
}

output "cluster_name" {
  description = "Name of the ECS cluster."
  value       = module.hub.cluster_name
}

output "service_name" {
  description = "Name of the hub ECS service."
  value       = module.hub.service_name
}

output "ecr_repository_url" {
  description = "URL of the hub image repository."
  value       = module.hub.ecr_repository_url
}
