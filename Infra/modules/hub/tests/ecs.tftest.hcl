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
}

mock_provider "aws" {
  alias = "copy"

  mock_resource "aws_backup_vault" {
    defaults = {
      arn = "arn:aws:backup:us-west-2:111111111111:backup-vault:b4hub-test-copy"
    }
  }
}

# The shared aws_iam_role mock gives every role one ARN; distinct ARNs here
# make the task-definition role wiring assertions able to fail.
override_resource {
  target = aws_iam_role.task_exec
  values = {
    arn = "arn:aws:iam::111111111111:role/b4hub-test-task-exec"
  }
}

override_resource {
  target = aws_iam_role.task
  values = {
    arn = "arn:aws:iam::111111111111:role/b4hub-test-task"
  }
}

override_resource {
  target = aws_iam_role.admin_task
  values = {
    arn = "arn:aws:iam::111111111111:role/b4hub-test-admin-task"
  }
}

variables {
  environment = "test"
  alarm_email = "ops@example.com"
}


run "single_task_recreate" {
  command = apply

  assert {
    condition     = aws_ecs_service.hub.deployment_minimum_healthy_percent == 0 && aws_ecs_service.hub.deployment_maximum_percent == 100
    error_message = "one task: stop the old task before starting the new one"
  }

  assert {
    condition     = aws_ecs_service.hub.deployment_circuit_breaker[0].enable == true && aws_ecs_service.hub.deployment_circuit_breaker[0].rollback == true
    error_message = "the circuit breaker rolls failed deployments back"
  }
}

run "two_tasks_rolling" {
  command = apply

  variables {
    task_count = 2
  }

  assert {
    condition     = aws_ecs_service.hub.deployment_minimum_healthy_percent == 100 && aws_ecs_service.hub.deployment_maximum_percent == 200
    error_message = "two tasks: roll with full capacity kept"
  }
}

run "service_shape" {
  command = apply

  assert {
    condition     = aws_ecs_service.hub.launch_type == "FARGATE" && aws_ecs_service.hub.desired_count == 0 && aws_ecs_service.hub.cluster == aws_ecs_cluster.hub.arn
    error_message = "Fargate service in the hub cluster, created with no tasks"
  }

  assert {
    condition     = aws_ecs_service.hub.health_check_grace_period_seconds == 60 && aws_ecs_service.hub.enable_execute_command == false
    error_message = "60-second grace period; no exec on serving tasks"
  }

  assert {
    condition     = aws_ecs_service.hub.propagate_tags == "SERVICE" && aws_ecs_service.hub.wait_for_steady_state == false
    error_message = "service tags propagate; apply does not wait for steady state"
  }

  assert {
    condition     = one(aws_ecs_service.hub.load_balancer).target_group_arn == aws_lb_target_group.hub.arn && one(aws_ecs_service.hub.load_balancer).container_name == "hub" && one(aws_ecs_service.hub.load_balancer).container_port == 8080
    error_message = "the hub container's port 8080 registers in the target group"
  }

  assert {
    condition     = one(aws_ecs_service.hub.network_configuration).assign_public_ip == true && one(aws_ecs_service.hub.network_configuration).subnets == toset(aws_subnet.public[*].id)
    error_message = "public subnets with public IPs by default"
  }

  assert {
    condition     = one(aws_ecs_service.hub.network_configuration).security_groups == toset([aws_security_group.task.id])
    error_message = "only the task security group is attached"
  }

  assert {
    condition     = aws_ecs_cluster.hub.name == "b4hub-test" && one([for s in aws_ecs_cluster.hub.setting : s.value if s.name == "containerInsights"]) == "enhanced"
    error_message = "cluster b4hub-test with enhanced Container Insights"
  }
}

run "private_tasks_subnets" {
  command = apply

  variables {
    private_tasks = true
  }

  assert {
    condition     = one(aws_ecs_service.hub.network_configuration).assign_public_ip == false && one(aws_ecs_service.hub.network_configuration).subnets == toset(aws_subnet.private[*].id)
    error_message = "private subnets without public IPs when private_tasks"
  }
}

run "serve_has_no_admin_url" {
  command = apply

  assert {
    condition     = !contains(jsondecode(aws_ecs_task_definition.hub.container_definitions)[0].secrets[*].name, "DATABASE_ADMIN_URL")
    error_message = "the serving task never receives the admin URL"
  }

  # Terraform's placeholder registration leaves the sign-in secrets out.
  assert {
    condition     = jsondecode(aws_ecs_task_definition.hub.container_definitions)[0].secrets[*].name == ["DATABASE_URL"]
    error_message = "the placeholder serving task has DATABASE_URL as its only secret"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.hub.container_definitions)[0].secrets[0].valueFrom == aws_secretsmanager_secret.this["database-url"].arn
    error_message = "DATABASE_URL comes from b4hub/database-url"
  }
}

run "serve_environment" {
  command = apply

  variables {
    hostname = "hub.test.b4.run"
  }

  assert {
    condition = { for e in jsondecode(aws_ecs_task_definition.hub.container_definitions)[0].environment : e.name => e.value } == {
      B4HUB_PORT                  = "8080"
      B4HUB_PUBLIC_URL            = "https://hub.test.b4.run"
      B4HUB_SIGNUP                = "open"
      B4HUB_WEBAUTHN_RP_ID        = "test.b4.run"
      B4HUB_APPLE_AUDIENCES       = "com.cacheplane.b4app.ios,com.cacheplane.b4app.signin"
      B4HUB_TRUST_X_FORWARDED_FOR = "1"
      B4HUB_RETENTION_DAYS        = "30"
      B4HUB_LOG                   = "info"
    }
    error_message = "the serving environment matches the image contract"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.hub.container_definitions)[0].command == ["serve"] && jsondecode(aws_ecs_task_definition.hub.container_definitions)[0].image == "ghcr.io/cacheplane/b4hub:main"
    error_message = "the placeholder runs the public image's serve command"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.hub.container_definitions)[0].portMappings[0].containerPort == 8080
    error_message = "the serving container exposes 8080"
  }
}

run "prod_rp_id" {
  command = apply

  variables {
    environment = "prod"
  }

  assert {
    condition     = one([for e in jsondecode(aws_ecs_task_definition.hub.container_definitions)[0].environment : e.value if e.name == "B4HUB_WEBAUTHN_RP_ID"]) == "b4.run"
    error_message = "hub.b4.run uses the b4.run relying party"
  }
}

run "signin_secrets_render" {
  command = apply

  assert {
    condition = jsondecode(templatefile("${path.module}/../../taskdefs/hub.json.tpl", {
      image                  = "img"
      region                 = "us-east-2"
      log_group              = "/b4hub/test/hub"
      environment_name       = "test"
      public_url             = "https://hub.test.b4.run"
      rp_id                  = "test.b4.run"
      db_url_secret_arn      = "arn:db-url"
      secret_key_arn         = "arn:secret-key"
      apple_team_id_arn      = "arn:team"
      apple_key_id_arn       = "arn:key"
      apple_private_key_arn  = "arn:private"
      include_signin_secrets = true
      }))[0].secrets == [
      { name = "B4HUB_SECRET_KEY", valueFrom = "arn:secret-key" },
      { name = "B4HUB_APPLE_TEAM_ID", valueFrom = "arn:team" },
      { name = "B4HUB_APPLE_KEY_ID", valueFrom = "arn:key" },
      { name = "B4HUB_APPLE_PRIVATE_KEY", valueFrom = "arn:private" },
      { name = "DATABASE_URL", valueFrom = "arn:db-url" },
    ]
    error_message = "with include_signin_secrets the template renders valid JSON with the four sign-in secrets"
  }
}

run "templates_render_valid_json" {
  command = apply

  assert {
    condition     = can(jsondecode(aws_ecs_task_definition.hub.container_definitions)) && can(jsondecode(aws_ecs_task_definition.migrate.container_definitions)) && can(jsondecode(aws_ecs_task_definition.admin.container_definitions))
    error_message = "all three templates render valid JSON"
  }

  assert {
    condition     = alltrue([for d in [aws_ecs_task_definition.hub, aws_ecs_task_definition.migrate, aws_ecs_task_definition.admin] : !strcontains(d.container_definitions, "$${") && !strcontains(d.container_definitions, "%%{")])
    error_message = "no unrendered placeholder remains"
  }
}

run "migrate_has_only_two_secrets" {
  command = apply

  assert {
    condition     = toset(jsondecode(aws_ecs_task_definition.migrate.container_definitions)[0].secrets[*].name) == toset(["DATABASE_ADMIN_URL", "DATABASE_URL"]) && length(jsondecode(aws_ecs_task_definition.migrate.container_definitions)[0].secrets) == 2
    error_message = "migrate receives exactly DATABASE_ADMIN_URL and DATABASE_URL"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.migrate.container_definitions)[0].command == ["migrate"]
    error_message = "the migrate task runs b4hub migrate"
  }
}

# The admin hub container runs `b4hub serve` only to stay alive for ECS Exec,
# so it also needs DATABASE_URL; it is operator-only and never serves traffic.
run "admin_hub_container_secrets" {
  command = apply

  assert {
    condition     = toset(one([for c in jsondecode(aws_ecs_task_definition.admin.container_definitions) : c if c.name == "hub"]).secrets[*].name) == toset(["DATABASE_ADMIN_URL", "DATABASE_URL"])
    error_message = "the admin hub container has the admin URL and the app URL, nothing else"
  }

  assert {
    condition     = one([for e in one([for c in jsondecode(aws_ecs_task_definition.admin.container_definitions) : c if c.name == "hub"]).environment : e.value if e.name == "B4HUB_PORT"]) == "8081"
    error_message = "the admin hub container listens on 8081"
  }

  assert {
    condition     = alltrue([for c in jsondecode(aws_ecs_task_definition.admin.container_definitions) : c.linuxParameters.initProcessEnabled == true])
    error_message = "both admin containers run an init process for ECS Exec"
  }
}

run "master_secret_only_in_admin_psql" {
  command = apply

  assert {
    condition     = !strcontains(aws_ecs_task_definition.hub.container_definitions, aws_db_instance.hub.master_user_secret[0].secret_arn) && !strcontains(aws_ecs_task_definition.migrate.container_definitions, aws_db_instance.hub.master_user_secret[0].secret_arn)
    error_message = "the master secret is in neither the serving nor the migrate task"
  }

  assert {
    condition     = !strcontains(jsonencode(one([for c in jsondecode(aws_ecs_task_definition.admin.container_definitions) : c if c.name == "hub"])), aws_db_instance.hub.master_user_secret[0].secret_arn)
    error_message = "the master secret is not in the admin hub container"
  }

  assert {
    condition     = one([for s in one([for c in jsondecode(aws_ecs_task_definition.admin.container_definitions) : c if c.name == "psql"]).secrets : s.valueFrom if s.name == "PGPASSWORD"]) == "${aws_db_instance.hub.master_user_secret[0].secret_arn}:password::"
    error_message = "the psql container reads PGPASSWORD from the master secret's password key"
  }
}

run "psql_container" {
  command = apply

  assert {
    condition     = one([for c in jsondecode(aws_ecs_task_definition.admin.container_definitions) : c if c.name == "psql"]).essential == true && one([for c in jsondecode(aws_ecs_task_definition.admin.container_definitions) : c if c.name == "psql"]).image == "public.ecr.aws/docker/library/postgres:17"
    error_message = "psql runs postgres:17"
  }

  assert {
    condition = { for e in one([for c in jsondecode(aws_ecs_task_definition.admin.container_definitions) : c if c.name == "psql"]).environment : e.name => e.value } == {
      PGHOST     = aws_db_instance.hub.address
      PGPORT     = "5432"
      PGUSER     = "b4hub_master"
      PGSSLMODE  = "require"
      PGDATABASE = "postgres"
    }
    error_message = "psql connects to the database as the master user over TLS"
  }
}

run "container_counts" {
  command = apply

  assert {
    condition     = length(jsondecode(aws_ecs_task_definition.hub.container_definitions)) == 1 && length(jsondecode(aws_ecs_task_definition.migrate.container_definitions)) == 1 && length(jsondecode(aws_ecs_task_definition.admin.container_definitions)) == 2
    error_message = "hub 1 container, migrate 1, admin 2"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.hub.container_definitions)[0].essential == true && jsondecode(aws_ecs_task_definition.migrate.container_definitions)[0].essential == true
    error_message = "the serving and migrate containers are essential"
  }

  # psql keeps the admin task alive on a fresh account, before the database
  # exists; the hub container may exit until migrate has run.
  assert {
    condition     = { for c in jsondecode(aws_ecs_task_definition.admin.container_definitions) : c.name => c.essential } == { hub = false, psql = true }
    error_message = "in the admin task psql is essential and hub is not"
  }
}

run "stop_timeout_60" {
  command = apply

  assert {
    condition     = alltrue(flatten([for d in [aws_ecs_task_definition.hub, aws_ecs_task_definition.migrate, aws_ecs_task_definition.admin] : [for c in jsondecode(d.container_definitions) : c.stopTimeout == 60]]))
    error_message = "every container gets 60 seconds to stop"
  }
}

run "task_definition_shape" {
  command = apply

  assert {
    condition     = { for k, d in { hub = aws_ecs_task_definition.hub, migrate = aws_ecs_task_definition.migrate, admin = aws_ecs_task_definition.admin } : k => d.family } == { hub = "b4hub-test-hub", migrate = "b4hub-test-hub-migrate", admin = "b4hub-test-hub-admin" }
    error_message = "families are b4hub-test-hub, -hub-migrate, -hub-admin"
  }

  assert {
    condition     = alltrue([for d in [aws_ecs_task_definition.hub, aws_ecs_task_definition.migrate, aws_ecs_task_definition.admin] : d.requires_compatibilities == toset(["FARGATE"]) && d.network_mode == "awsvpc" && d.cpu == "256" && d.memory == "512"])
    error_message = "Fargate, awsvpc, 256 CPU, 512 MiB"
  }

  assert {
    condition     = alltrue([for d in [aws_ecs_task_definition.hub, aws_ecs_task_definition.migrate, aws_ecs_task_definition.admin] : one(d.runtime_platform).cpu_architecture == "ARM64" && one(d.runtime_platform).operating_system_family == "LINUX"])
    error_message = "ARM64 Linux"
  }

  assert {
    condition     = alltrue([for d in [aws_ecs_task_definition.hub, aws_ecs_task_definition.migrate, aws_ecs_task_definition.admin] : d.execution_role_arn == aws_iam_role.task_exec.arn])
    error_message = "every task definition uses the execution role"
  }

  assert {
    condition     = alltrue([for d in [aws_ecs_task_definition.hub, aws_ecs_task_definition.migrate, aws_ecs_task_definition.admin] : alltrue([for c in jsondecode(d.container_definitions) : c.logConfiguration.logDriver == "awslogs" && c.logConfiguration.options["awslogs-region"] == "us-east-2"])])
    error_message = "every container logs to CloudWatch in the region"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.hub.container_definitions)[0].logConfiguration.options["awslogs-group"] == "/b4hub/test/hub" && jsondecode(aws_ecs_task_definition.migrate.container_definitions)[0].logConfiguration.options["awslogs-group"] == "/b4hub/test/migrate" && alltrue([for c in jsondecode(aws_ecs_task_definition.admin.container_definitions) : c.logConfiguration.options["awslogs-group"] == "/b4hub/test/admin"])
    error_message = "each task logs to its own group"
  }

  assert {
    condition     = alltrue([for c in concat(jsondecode(aws_ecs_task_definition.hub.container_definitions), jsondecode(aws_ecs_task_definition.migrate.container_definitions), [for c in jsondecode(aws_ecs_task_definition.admin.container_definitions) : c if c.name == "hub"]) : c.readonlyRootFilesystem == true && c.mountPoints == [{ sourceVolume = "tmp", containerPath = "/tmp", readOnly = false }]])
    error_message = "hub containers have a read-only root and a writable /tmp"
  }

  assert {
    condition     = alltrue([for d in [aws_ecs_task_definition.hub, aws_ecs_task_definition.migrate, aws_ecs_task_definition.admin] : [for v in d.volume : v.name] == ["tmp"]])
    error_message = "every task definition declares the tmp volume"
  }

  assert {
    condition     = alltrue(flatten([for d in [aws_ecs_task_definition.hub, aws_ecs_task_definition.migrate, aws_ecs_task_definition.admin] : [for c in jsondecode(d.container_definitions) : !contains(keys(c), "healthCheck")]]))
    error_message = "no container health check: the load balancer checks /readyz"
  }
}

run "task_roles" {
  command = apply

  assert {
    condition     = aws_ecs_task_definition.hub.task_role_arn == aws_iam_role.task.arn && aws_ecs_task_definition.migrate.task_role_arn == aws_iam_role.task.arn && aws_ecs_task_definition.admin.task_role_arn == aws_iam_role.admin_task.arn
    error_message = "serving and migrate use the task role; admin uses the admin task role"
  }

  assert {
    condition     = [for r in [aws_iam_role.task_exec, aws_iam_role.task, aws_iam_role.admin_task] : r.name] == ["b4hub-test-task-exec", "b4hub-test-task", "b4hub-test-admin-task"]
    error_message = "role names"
  }

  assert {
    condition     = alltrue([for r in [aws_iam_role.task_exec, aws_iam_role.task, aws_iam_role.admin_task] : r.permissions_boundary == "arn:aws:iam::111111111111:policy/b4hub-test-boundary"])
    error_message = "every role carries the permissions boundary"
  }

  assert {
    condition     = alltrue([for r in [aws_iam_role.task_exec, aws_iam_role.task, aws_iam_role.admin_task] : jsondecode(r.assume_role_policy).Statement[0].Principal.Service == "ecs-tasks.amazonaws.com"])
    error_message = "every role trusts ECS tasks"
  }

  assert {
    condition     = alltrue([for r in [aws_iam_role.task_exec, aws_iam_role.task, aws_iam_role.admin_task] : jsondecode(r.assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceAccount"] == "111111111111"])
    error_message = "every trust policy is limited to this account's tasks"
  }

  assert {
    condition     = length(toset([aws_iam_role.task_exec.arn, aws_iam_role.task.arn, aws_iam_role.admin_task.arn])) == 3
    error_message = "the three roles have distinct ARNs in this test, so the wiring assertions are meaningful"
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.admin_task_exec.policy).Statement == [{ Sid = "EcsExec", Effect = "Allow", Action = ["ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel", "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel"], Resource = "*" }]
    error_message = "the admin task role allows only the ECS Exec channel actions"
  }
}

run "exec_role_reads_only_known_secrets" {
  command = apply

  assert {
    condition     = toset(one([for s in jsondecode(aws_iam_role_policy.task_exec.policy).Statement : s if s.Sid == "ReadSecrets"]).Resource) == toset(concat(values(aws_secretsmanager_secret.this)[*].arn, [aws_db_instance.hub.master_user_secret[0].secret_arn]))
    error_message = "the execution role reads the six hub secrets and the master secret, nothing else"
  }

  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.task_exec.policy).Statement : s if s.Sid == "ReadSecrets"]).Action == "secretsmanager:GetSecretValue"
    error_message = "secrets are read with GetSecretValue only"
  }

  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.task_exec.policy).Statement : s if s.Sid == "DecryptSecrets"]).Resource == aws_kms_key.this.arn
    error_message = "the execution role decrypts with the account key"
  }

  assert {
    condition     = toset(one([for s in jsondecode(aws_iam_role_policy.task_exec.policy).Statement : s if s.Sid == "PullImage"]).Resource) == toset([aws_ecr_repository.hub.arn])
    error_message = "image pulls are scoped to the hub repository"
  }

  assert {
    condition     = toset(one([for s in jsondecode(aws_iam_role_policy.task_exec.policy).Statement : s if s.Sid == "WriteLogs"]).Resource) == toset([for g in aws_cloudwatch_log_group.hub : "${g.arn}:log-stream:*"])
    error_message = "log writes are scoped to the three log groups"
  }
}

run "ecr_and_logs" {
  command = apply

  assert {
    condition     = aws_ecr_repository.hub.name == "b4hub" && aws_ecr_repository.hub.image_tag_mutability == "IMMUTABLE" && aws_ecr_repository.hub.image_scanning_configuration[0].scan_on_push == true
    error_message = "immutable b4hub repository scanned on push"
  }

  assert {
    condition     = { for k, g in aws_cloudwatch_log_group.hub : k => g.name } == { hub = "/b4hub/test/hub", migrate = "/b4hub/test/migrate", admin = "/b4hub/test/admin" }
    error_message = "three log groups under /b4hub/test"
  }

  assert {
    condition     = alltrue([for g in aws_cloudwatch_log_group.hub : g.retention_in_days == 30])
    error_message = "log retention follows log_retention_days"
  }
}
