locals {
  log_groups = {
    hub     = "/b4hub/${var.environment}/hub"
    migrate = "/b4hub/${var.environment}/migrate"
    admin   = "/b4hub/${var.environment}/admin"
  }

  taskdef_families = {
    hub     = "${local.name}-hub"
    migrate = "${local.name}-hub-migrate"
    admin   = "${local.name}-hub-admin"
  }

  # The task definition templates live outside the module, in Infra/taskdefs,
  # because the CI renderer shares them. So roots must source this module by
  # a relative in-repo path (source = "../../modules/hub") or a git source
  # with a //Infra/modules/hub subdirectory. An absolute local path is copied
  # into .terraform/modules without the templates, and templatefile fails.
  taskdef_dir = "${path.module}/../../taskdefs"

  # Terraform registers placeholder revisions so the service can be created
  # with desired_count = 0; the first CI deploy renders the same templates
  # with the ECR digest and registers the revision that actually runs.
  placeholder_image = "ghcr.io/cacheplane/b4hub:main"

  # hub.b4.run -> b4.run, hub.test.b4.run -> test.b4.run
  webauthn_rp_id = trimprefix(var.hostname, "hub.")
}

resource "aws_cloudwatch_log_group" "hub" {
  for_each = local.log_groups

  name              = each.value
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_cluster" "hub" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = "enhanced"
  }
}

# Task definitions. Containers run with a read-only root filesystem; /tmp is
# a bind mount of the task's ephemeral storage (the "tmp" volume), because
# Fargate does not support linuxParameters.tmpfs. No container healthCheck:
# the load balancer checks /readyz, and ECS ignores the image's HEALTHCHECK.

resource "aws_ecs_task_definition" "hub" {
  family                   = local.taskdef_families.hub
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.task_exec.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  volume {
    name = "tmp"
  }

  container_definitions = templatefile("${local.taskdef_dir}/hub.json.tpl", {
    image                 = local.placeholder_image
    region                = var.region
    log_group             = aws_cloudwatch_log_group.hub["hub"].name
    environment_name      = var.environment
    public_url            = "https://${var.hostname}"
    rp_id                 = local.webauthn_rp_id
    db_url_secret_arn     = aws_secretsmanager_secret.this["database-url"].arn
    secret_key_arn        = aws_secretsmanager_secret.this["secret-key"].arn
    apple_team_id_arn     = aws_secretsmanager_secret.this["apple-team-id"].arn
    apple_key_id_arn      = aws_secretsmanager_secret.this["apple-key-id"].arn
    apple_private_key_arn = aws_secretsmanager_secret.this["apple-private-key"].arn
    # The sign-in hub is not on main yet, and ECS refuses to start a task
    # whose secret has no value; the placeholder leaves those four out.
    include_signin_secrets = false
  })
}

resource "aws_ecs_task_definition" "migrate" {
  family                   = local.taskdef_families.migrate
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.task_exec.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  volume {
    name = "tmp"
  }

  container_definitions = templatefile("${local.taskdef_dir}/hub-migrate.json.tpl", {
    image                   = local.placeholder_image
    region                  = var.region
    log_group               = aws_cloudwatch_log_group.hub["migrate"].name
    db_admin_url_secret_arn = aws_secretsmanager_secret.this["database-admin-url"].arn
    db_url_secret_arn       = aws_secretsmanager_secret.this["database-url"].arn
  })
}

# Run ad hoc by an operator with --enable-execute-command (a RunTask flag, not
# a task-definition attribute). Two containers (JSON has no comments, so the
# template's ordering is explained here):
# - psql (essential): postgres client as the RDS master user, the only place
#   the master secret is used. It is the essential container so the task
#   lives (sleep 3600) on a fresh account, before the b4hub database and
#   b4hub_app role exist: the operator creates them from psql first.
# - hub (not essential): the hub image has no shell, so it runs `b4hub serve`
#   on 8081 only to stay alive for ECS Exec; the operator execs
#   `b4hub seed|enroll` in it. serve connects at startup, so before the
#   database exists and `migrate` has run it exits without stopping the task;
#   after migrate it stays up. serve needs DATABASE_URL and seed/enroll need
#   DATABASE_ADMIN_URL, so it gets both. It is operator-only and never
#   receives traffic.
# psql: PGSSLMODE is require, not verify-full: the postgres image
#   lacks the RDS CA bundle. require still encrypts; the hub itself verifies
#   the server with the bundle baked into its image.
resource "aws_ecs_task_definition" "admin" {
  family                   = local.taskdef_families.admin
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.task_exec.arn
  task_role_arn            = aws_iam_role.admin_task.arn

  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  volume {
    name = "tmp"
  }

  container_definitions = templatefile("${local.taskdef_dir}/hub-admin.json.tpl", {
    image                   = local.placeholder_image
    psql_image              = var.admin_psql_image
    region                  = var.region
    log_group               = aws_cloudwatch_log_group.hub["admin"].name
    db_admin_url_secret_arn = aws_secretsmanager_secret.this["database-admin-url"].arn
    db_url_secret_arn       = aws_secretsmanager_secret.this["database-url"].arn
    db_master_secret_arn    = aws_db_instance.hub.master_user_secret[0].secret_arn
    db_host                 = aws_db_instance.hub.address
  })
}

resource "aws_ecs_service" "hub" {
  name            = "${local.name}-hub"
  cluster         = aws_ecs_cluster.hub.arn
  task_definition = aws_ecs_task_definition.hub.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # One task: stop it before starting the replacement (brief downtime, no
  # double capacity). Two or more: roll with full capacity kept.
  deployment_minimum_healthy_percent = var.task_count > 1 ? 100 : 0
  deployment_maximum_percent         = var.task_count > 1 ? 200 : 100

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  health_check_grace_period_seconds = 60
  enable_execute_command            = false
  propagate_tags                    = "SERVICE"
  wait_for_steady_state             = false

  network_configuration {
    subnets          = var.private_tasks ? aws_subnet.private[*].id : aws_subnet.public[*].id
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = !var.private_tasks
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.hub.arn
    container_name   = "hub"
    container_port   = 8080
  }

  # CI deploys new task definition revisions and may scale the service; a
  # later apply must not roll either back.
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_lb_listener.https]
}
