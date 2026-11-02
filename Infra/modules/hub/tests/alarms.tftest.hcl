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
      arn        = "arn:aws:elasticloadbalancing:us-east-2:111111111111:loadbalancer/app/b4hub-test/0123456789abcdef"
      arn_suffix = "app/b4hub-test/0123456789abcdef"
    }
  }

  mock_resource "aws_lb_target_group" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:us-east-2:111111111111:targetgroup/b4hub-test-hub/0123456789abcdef"
      arn_suffix = "targetgroup/b4hub-test-hub/0123456789abcdef"
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

run "alarm_count" {
  command = apply

  assert {
    condition = toset([
      aws_cloudwatch_metric_alarm.alb_5xx.alarm_name,
      aws_cloudwatch_metric_alarm.unhealthy_hosts.alarm_name,
      aws_cloudwatch_metric_alarm.latency_p99.alarm_name,
      aws_cloudwatch_metric_alarm.rds_free_storage.alarm_name,
      aws_cloudwatch_metric_alarm.rds_cpu.alarm_name,
      aws_cloudwatch_metric_alarm.rds_connections.alarm_name,
    ]) == toset([for n in ["alb-5xx", "unhealthy-hosts", "latency-p99", "rds-free-storage", "rds-cpu", "rds-connections"] : "b4hub-test-${n}"])
    error_message = "six alarms exist whatever the desired count"
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.running_tasks) == 0
    error_message = "the running-tasks alarm is the seventh and is absent at desired_count 0"
  }
}

run "seven_alarms_when_serving" {
  command = apply

  variables {
    desired_count = 1
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.running_tasks) == 1
    error_message = "the seventh alarm exists once the service is meant to run"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.running_tasks[0].namespace == "ECS/ContainerInsights" && aws_cloudwatch_metric_alarm.running_tasks[0].metric_name == "RunningTaskCount" && aws_cloudwatch_metric_alarm.running_tasks[0].comparison_operator == "LessThanThreshold" && aws_cloudwatch_metric_alarm.running_tasks[0].threshold == 1
    error_message = "RunningTaskCount below 1 from Container Insights"
  }
}

run "running_task_alarm_off_when_zero" {
  command = apply

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.running_tasks) == 0
    error_message = "no running-task alarm while desired_count is 0"
  }
}

run "alarm_shapes" {
  command = apply

  assert {
    condition     = aws_cloudwatch_metric_alarm.alb_5xx.statistic == "Sum" && aws_cloudwatch_metric_alarm.alb_5xx.period == 300 && aws_cloudwatch_metric_alarm.alb_5xx.threshold == 5 && aws_cloudwatch_metric_alarm.alb_5xx.comparison_operator == "GreaterThanOrEqualToThreshold"
    error_message = "5xx: sum >= 5 over 300 s"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.unhealthy_hosts.evaluation_periods == 2 && aws_cloudwatch_metric_alarm.unhealthy_hosts.datapoints_to_alarm == 2 && aws_cloudwatch_metric_alarm.unhealthy_hosts.period == 60
    error_message = "unhealthy hosts: 2 of 2 periods of 60 s"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.latency_p99.extended_statistic == "p99" && aws_cloudwatch_metric_alarm.latency_p99.threshold == 2 && aws_cloudwatch_metric_alarm.latency_p99.evaluation_periods == 10
    error_message = "latency: p99 > 2 s for 10 periods"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.rds_free_storage.threshold == 2147483648 && aws_cloudwatch_metric_alarm.rds_cpu.threshold == 80 && aws_cloudwatch_metric_alarm.rds_cpu.evaluation_periods == 3 && aws_cloudwatch_metric_alarm.rds_cpu.period == 300 && aws_cloudwatch_metric_alarm.rds_connections.threshold == 60
    error_message = "RDS: 2 GiB free storage, CPU 80 for 15 min, 60 connections"
  }

  assert {
    condition     = contains(aws_cloudwatch_metric_alarm.rds_cpu.alarm_actions, aws_sns_topic.alerts.arn) && contains(aws_cloudwatch_metric_alarm.rds_cpu.ok_actions, aws_sns_topic.alerts.arn)
    error_message = "alarms notify the topic on alarm and recovery"
  }
}

run "migrate_event_rule" {
  command = apply

  assert {
    condition     = jsondecode(aws_cloudwatch_event_rule.migrate_stopped.event_pattern).source == ["aws.ecs"] && jsondecode(aws_cloudwatch_event_rule.migrate_stopped.event_pattern)["detail-type"] == ["ECS Task State Change"]
    error_message = "the rule watches ECS task state changes"
  }

  assert {
    condition     = jsondecode(aws_cloudwatch_event_rule.migrate_stopped.event_pattern).detail.lastStatus == ["STOPPED"] && jsondecode(aws_cloudwatch_event_rule.migrate_stopped.event_pattern).detail.clusterArn == [aws_ecs_cluster.hub.arn]
    error_message = "stopped tasks in the hub cluster"
  }

  assert {
    condition     = jsondecode(aws_cloudwatch_event_rule.migrate_stopped.event_pattern).detail.taskDefinitionArn[0].prefix == "arn:aws:ecs:us-east-2:111111111111:task-definition/b4hub-test-hub-migrate:"
    error_message = "only the migrate family, matched with the colon so the hub family cannot match"
  }
}

run "budget_threshold" {
  command = apply

  assert {
    condition     = aws_budgets_budget.monthly.limit_amount == "70" && aws_budgets_budget.monthly.time_unit == "MONTHLY" && aws_budgets_budget.monthly.budget_type == "COST"
    error_message = "monthly cost budget at the variable's amount"
  }

  assert {
    condition     = one(aws_budgets_budget.monthly.notification).threshold == 150 && one(aws_budgets_budget.monthly.notification).notification_type == "ACTUAL" && one(aws_budgets_budget.monthly.notification).threshold_type == "PERCENTAGE" && one(aws_budgets_budget.monthly.notification).comparison_operator == "GREATER_THAN"
    error_message = "notify when actual spend exceeds 150 percent"
  }
}
