# tflint-ignore-file: terraform_unused_declarations
# This module is built up over several files; the variables below are the
# complete surface, and the ones not yet referenced are consumed by files added
# in later tasks (marked "used by"), so the unused-declarations rule is off here.

variable "environment" {
  description = "Account this environment is applied to: test or prod. Selects the VPC range."
  type        = string

  validation {
    condition     = contains(["test", "prod"], var.environment)
    error_message = "environment must be test or prod."
  }
}

variable "region" {
  description = "AWS region of the environment; the subnets use its a and b zones."
  type        = string
  default     = "us-east-2"
}

variable "hostname" {
  description = "Public hostname of the hub." # used by alb.tf
  type        = string
  default     = "hub.b4.run"
}

variable "private_tasks" {
  description = "Run tasks in private subnets behind a NAT gateway (true) or in public subnets with public IPs (false)."
  type        = bool
  default     = false
}

variable "task_count" {
  description = "Number of Fargate tasks the service is sized for." # used by ecs.tf
  type        = number
  default     = 1
}

variable "desired_count" {
  description = "Initial desired task count of the ECS service." # used by ecs.tf
  type        = number
  default     = 0
}

variable "db_instance_class" {
  description = "RDS instance class." # used by rds.tf
  type        = string
  default     = "db.t4g.micro"
}

variable "db_multi_az" {
  description = "Run the database in two availability zones." # used by rds.tf
  type        = bool
  default     = false
}

variable "db_backup_retention_days" {
  description = "Days of automated database backups to keep." # used by rds.tf
  type        = number
  default     = 7
}

variable "backup_copy_region" {
  description = "Region that receives cross-region backup copies; null disables the copy." # used by rds.tf
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "Days to keep CloudWatch logs."
  type        = number
  default     = 30
}

variable "alarm_email" {
  description = "Email address subscribed to the alarm topic." # used by observability.tf
  type        = string
}

variable "alb_ssl_policy" {
  description = "TLS policy of the HTTPS listener." # used by alb.tf
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-Res-2021-06"
}

variable "admin_psql_image" {
  description = "Image of the admin task's psql container."
  type        = string
  default     = "public.ecr.aws/docker/library/postgres:17"
}
