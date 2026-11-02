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

  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:us-east-2:111111111111:b4hub-test-alerts"
    }
  }

  mock_resource "aws_cloudwatch_event_rule" {
    defaults = {
      arn = "arn:aws:events:us-east-2:111111111111:rule/b4hub-test-migrate-stopped"
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
  environment        = "test"
  alarm_email        = "ops@example.com"
  monthly_budget_usd = 70
}

run "no_nat_by_default" {
  command = plan

  assert {
    condition     = length(aws_nat_gateway.this) == 0
    error_message = "no NAT gateway unless private_tasks is true"
  }

  assert {
    condition     = length(aws_eip.nat) == 0
    error_message = "no NAT elastic IP unless private_tasks is true"
  }

  assert {
    condition     = length(aws_route.private_default) == 0
    error_message = "private route table has no default route without NAT"
  }
}

run "nat_when_private" {
  command = plan

  variables {
    private_tasks = true
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 1
    error_message = "exactly one NAT gateway when private_tasks is true"
  }

  assert {
    condition     = length(aws_route.private_default) == 1
    error_message = "private default route exists when private_tasks is true"
  }
}

run "vpc_cidr_by_environment" {
  command = plan

  assert {
    condition     = aws_vpc.this.cidr_block == "10.10.0.0/16"
    error_message = "test uses 10.10.0.0/16"
  }

  assert {
    condition     = aws_subnet.public[0].cidr_block == "10.10.0.0/20" && aws_subnet.public[1].cidr_block == "10.10.16.0/20"
    error_message = "public subnets are the first two /20s"
  }

  assert {
    condition     = aws_subnet.private[0].cidr_block == "10.10.32.0/20" && aws_subnet.private[1].cidr_block == "10.10.48.0/20"
    error_message = "private subnets are the next two /20s"
  }

  assert {
    condition     = aws_subnet.public[0].availability_zone == "us-east-2a" && aws_subnet.public[1].availability_zone == "us-east-2b"
    error_message = "public subnets span zones a and b"
  }

  assert {
    condition     = aws_subnet.private[0].availability_zone == "us-east-2a" && aws_subnet.private[1].availability_zone == "us-east-2b"
    error_message = "private subnets span zones a and b"
  }
}

run "prod_cidr" {
  command = plan

  variables {
    environment = "prod"
  }

  assert {
    condition     = aws_vpc.this.cidr_block == "10.20.0.0/16"
    error_message = "prod uses 10.20.0.0/16"
  }
}

run "task_sg_only_from_alb" {
  command = apply

  assert {
    condition     = aws_vpc_security_group_ingress_rule.task_from_alb.referenced_security_group_id == aws_security_group.alb.id
    error_message = "task ingress comes only from the ALB security group"
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.task_from_alb.from_port == 8080 && aws_vpc_security_group_ingress_rule.task_from_alb.to_port == 8080
    error_message = "task ingress is port 8080"
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.task_from_alb.cidr_ipv4 == null
    error_message = "task ingress has no CIDR source"
  }
}

run "alb_sg_rules" {
  command = apply

  assert {
    condition     = aws_vpc_security_group_ingress_rule.alb_https.from_port == 443 && aws_vpc_security_group_ingress_rule.alb_https.cidr_ipv4 == "0.0.0.0/0"
    error_message = "ALB accepts 443 from anywhere"
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.alb_http.from_port == 80 && aws_vpc_security_group_ingress_rule.alb_http.cidr_ipv4 == "0.0.0.0/0"
    error_message = "ALB accepts 80 from anywhere (for the redirect)"
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.alb_to_task.referenced_security_group_id == aws_security_group.task.id && aws_vpc_security_group_egress_rule.alb_to_task.from_port == 8080
    error_message = "ALB egress is 8080 to the task security group only"
  }
}

run "db_has_no_public_ingress" {
  command = apply

  assert {
    condition     = aws_vpc_security_group_ingress_rule.db_from_task.cidr_ipv4 == null && aws_vpc_security_group_ingress_rule.db_from_admin.cidr_ipv4 == null
    error_message = "db ingress rules have no CIDR source"
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.db_from_task.referenced_security_group_id == aws_security_group.task.id && aws_vpc_security_group_ingress_rule.db_from_admin.referenced_security_group_id == aws_security_group.admin.id
    error_message = "db ingress comes from the task and admin security groups"
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.db_from_task.from_port == 5432 && aws_vpc_security_group_ingress_rule.db_from_admin.from_port == 5432
    error_message = "db ingress is port 5432"
  }
}

run "task_and_admin_egress" {
  command = apply

  assert {
    condition     = aws_vpc_security_group_egress_rule.task_https.from_port == 443 && aws_vpc_security_group_egress_rule.task_https.cidr_ipv4 == "0.0.0.0/0"
    error_message = "task egress 443 anywhere"
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.task_to_db.from_port == 5432 && aws_vpc_security_group_egress_rule.task_to_db.referenced_security_group_id == aws_security_group.db.id
    error_message = "task egress 5432 to the db security group only"
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.admin_https.from_port == 443 && aws_vpc_security_group_egress_rule.admin_https.cidr_ipv4 == "0.0.0.0/0"
    error_message = "admin egress 443 anywhere"
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.admin_to_db.from_port == 5432 && aws_vpc_security_group_egress_rule.admin_to_db.referenced_security_group_id == aws_security_group.db.id
    error_message = "admin egress 5432 to the db security group only"
  }
}

run "s3_endpoint_on_both_route_tables" {
  command = apply

  assert {
    condition     = aws_vpc_endpoint.s3.vpc_endpoint_type == "Gateway" && aws_vpc_endpoint.s3.service_name == "com.amazonaws.us-east-2.s3"
    error_message = "S3 gateway endpoint in the region"
  }

  assert {
    condition     = length(aws_vpc_endpoint_route_table_association.s3) == 2
    error_message = "S3 endpoint is attached to the public and private route tables"
  }
}
