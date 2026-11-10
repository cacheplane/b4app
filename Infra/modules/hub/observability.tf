# Alarms, the migrate-failure event rule, and the cost budget all notify one
# SNS topic with an email subscription (the owner confirms it once).

# The topic is deliberately not encrypted. CloudWatch alarms and EventBridge
# cannot publish to a topic encrypted with a customer-managed key unless the
# key policy allows them, and rewriting the account key's policy is not worth
# it at this tier: the messages carry alarm names and metric values only.
resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

resource "aws_sns_topic_subscription" "alarm_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # The SNS API refuses a wildcard action in a topic policy ("Policy
        # statement action out of service scope"), so the actions are listed.
        Sid       = "OwnerManages"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action = [
          "sns:GetTopicAttributes",
          "sns:SetTopicAttributes",
          "sns:AddPermission",
          "sns:RemovePermission",
          "sns:DeleteTopic",
          "sns:Subscribe",
          "sns:ListSubscriptionsByTopic",
          "sns:Publish",
        ]
        Resource = aws_sns_topic.alerts.arn
      },
      {
        Sid       = "CloudWatchAlarmsPublish"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.alerts.arn
        Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
      },
      {
        Sid       = "EventRulesPublish"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.alerts.arn
        Condition = { ArnEquals = { "aws:SourceArn" = [aws_cloudwatch_event_rule.migrate_stopped.arn, aws_cloudwatch_event_rule.backup_copy_failed.arn] } }
      },
    ]
  })
}

# Application load balancer
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${local.name}-alb-5xx"
  alarm_description   = "Five or more 5xx responses from the hub within five minutes."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  dimensions = {
    LoadBalancer = aws_lb.this.arn_suffix
    TargetGroup  = aws_lb_target_group.hub.arn_suffix
  }
}

# Gated like running_tasks: with no tasks (desired_count 0) there are no
# targets, and "missing data is breaching" would fire from the first apply. A
# single-task recreate deploy also leaves a gap, so the alarm needs two
# consecutive 60 s periods to fire.
resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  count = var.desired_count > 0 ? 1 : 0

  alarm_name          = "${local.name}-unhealthy-hosts"
  alarm_description   = "The target group has had an unhealthy task for two minutes."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  # While the service is meant to run, no data means no targets are reporting,
  # which is a failure that should page.
  treat_missing_data = "breaching"
  alarm_actions      = [aws_sns_topic.alerts.arn]
  ok_actions         = [aws_sns_topic.alerts.arn]
  dimensions = {
    LoadBalancer = aws_lb.this.arn_suffix
    TargetGroup  = aws_lb_target_group.hub.arn_suffix
  }
}

# Latency is measured from the hub's own request log, not the load balancer's
# TargetResponseTime: the sync long-poll (`GET /v1/changes`, up to 25 s) and
# the relay's WebSocket upgrade are legitimately slow, and with a few devices
# connected they are most of the traffic, so the ALB's p99 sat at 25 s and the
# alarm was in ALARM from the first day (2026-11-02 to 2026-11-09). The filter
# publishes every other request's elapsed_ms as a metric value.
resource "aws_cloudwatch_log_metric_filter" "request_latency" {
  name           = "${local.name}-request-latency"
  log_group_name = aws_cloudwatch_log_group.hub["hub"].name
  pattern        = "{ ($.message = \"request complete\") && ($.span.path != \"/v1/changes\") && ($.span.path != \"/v1/devices/self/link\") }"

  metric_transformation {
    name      = "RequestLatencyMs"
    namespace = "b4hub/${local.name}"
    value     = "$.elapsed_ms"
    unit      = "Milliseconds"
  }
}

resource "aws_cloudwatch_metric_alarm" "latency_p99" {
  alarm_name          = "${local.name}-latency-p99"
  alarm_description   = "p99 request latency (long polls excluded) above two seconds for ten minutes."
  namespace           = "b4hub/${local.name}"
  metric_name         = "RequestLatencyMs"
  extended_statistic  = "p99"
  period              = 60
  evaluation_periods  = 10
  datapoints_to_alarm = 10
  threshold           = 2000
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  depends_on = [aws_cloudwatch_log_metric_filter.request_latency]
}

# ECS: only while the service is meant to have tasks. The root creates it with
# desired_count 0 and flips to 1 after the first deploy; without this guard the
# alarm would fire from the first apply onward.
resource "aws_cloudwatch_metric_alarm" "running_tasks" {
  count = var.desired_count > 0 ? 1 : 0

  alarm_name          = "${local.name}-running-tasks"
  alarm_description   = "The hub service has no running task."
  namespace           = "ECS/ContainerInsights"
  metric_name         = "RunningTaskCount"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  dimensions = {
    ClusterName = aws_ecs_cluster.hub.name
    ServiceName = aws_ecs_service.hub.name
  }
}

# Database
resource "aws_cloudwatch_metric_alarm" "rds_free_storage" {
  alarm_name          = "${local.name}-rds-free-storage"
  alarm_description   = "Less than 2 GiB of database storage is free."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 2147483648 # 2 GiB
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  dimensions          = { DBInstanceIdentifier = aws_db_instance.hub.identifier }
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${local.name}-rds-cpu"
  alarm_description   = "Database CPU above 80 percent for 15 minutes."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  dimensions          = { DBInstanceIdentifier = aws_db_instance.hub.identifier }
}

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "${local.name}-rds-connections"
  alarm_description   = "More than 60 database connections."
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 60
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  dimensions          = { DBInstanceIdentifier = aws_db_instance.hub.identifier }
}

# Migrations. An EventBridge pattern cannot express "exit code is not zero", so
# this matches every stopped migrate task and the email states the stop code and
# exit code; a clean run is also one email. The deploy workflow checks the exit
# code itself and is the gate. The ":" ends the family name so the hub and
# admin families cannot match.
# A failed backup copy job (the nightly copy to the copy vault, or the
# on-demand copy of runbook 8 B) is reported by AWS Backup in the source
# region as an event, never as a metric; the first one failed silently on
# 2026-11-03 until an operator looked. The rule is created in every
# environment; with no copy region it simply never matches.
resource "aws_cloudwatch_event_rule" "backup_copy_failed" {
  name        = "${local.name}-backup-copy-failed"
  description = "An AWS Backup copy job for the hub failed."
  event_pattern = jsonencode({
    source        = ["aws.backup"]
    "detail-type" = ["Copy Job State Change"]
    detail = {
      state = ["FAILED"]
    }
  })
}

resource "aws_cloudwatch_event_target" "backup_copy_failed" {
  rule      = aws_cloudwatch_event_rule.backup_copy_failed.name
  target_id = "${local.name}-alerts"
  arn       = aws_sns_topic.alerts.arn

  depends_on = [aws_sns_topic_policy.alerts]
}

resource "aws_cloudwatch_event_rule" "migrate_stopped" {
  name        = "${local.name}-migrate-stopped"
  description = "A hub migrate task stopped."
  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Task State Change"]
    detail = {
      lastStatus        = ["STOPPED"]
      clusterArn        = [aws_ecs_cluster.hub.arn]
      taskDefinitionArn = [{ prefix = "arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:task-definition/${local.taskdef_families.migrate}:" }]
    }
  })
}

resource "aws_cloudwatch_event_target" "migrate_stopped" {
  rule      = aws_cloudwatch_event_rule.migrate_stopped.name
  target_id = "alerts"
  arn       = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths = {
      group    = "$.detail.group"
      stopCode = "$.detail.stopCode"
      exitCode = "$.detail.containers[0].exitCode"
      reason   = "$.detail.stoppedReason"
    }
    input_template = "\"Migrate task <group> stopped: stopCode <stopCode>, exit code <exitCode>. <reason>\""
  }

  depends_on = [aws_sns_topic_policy.alerts]
}

resource "aws_budgets_budget" "monthly" {
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  time_unit    = "MONTHLY"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 150
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alarm_email]
  }
}
