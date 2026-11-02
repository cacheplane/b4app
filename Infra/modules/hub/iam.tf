locals {
  # The bootstrap boundary denies creating a role without it.
  boundary_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${local.name}-boundary"

  ecs_tasks_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      # Only tasks in this account may assume the role (confused deputy).
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })

  # What the execution role may read: the six hub secrets and the RDS-managed
  # master secret (the admin task's psql container only).
  task_secret_arns = concat(
    [for k in local.secret_names : aws_secretsmanager_secret.this[k].arn],
    [aws_db_instance.hub.master_user_secret[0].secret_arn],
  )
}

# Execution role: what ECS itself needs to start a task (pull the image,
# resolve secrets, create the log stream). The containers never hold it.
resource "aws_iam_role" "task_exec" {
  name                 = "${local.name}-task-exec"
  permissions_boundary = local.boundary_arn
  assume_role_policy   = local.ecs_tasks_trust
}

resource "aws_iam_role_policy" "task_exec" {
  name = "${local.name}-task-exec"
  role = aws_iam_role.task_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Not resource-scopable.
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "PullImage"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = [aws_ecr_repository.hub.arn]
      },
      {
        Sid      = "ReadSecrets"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = local.task_secret_arns
      },
      {
        # Every secret, the master secret included, is encrypted with the
        # account key; without this, task startup fails resolving secrets.
        Sid      = "DecryptSecrets"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = aws_kms_key.this.arn
      },
      {
        Sid      = "WriteLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = [for g in aws_cloudwatch_log_group.hub : "${g.arn}:log-stream:*"]
      },
    ]
  })
}

# Task role of the serving and migrate tasks. The hub calls no AWS API, so it
# has no policy at all.
resource "aws_iam_role" "task" {
  name                 = "${local.name}-task"
  permissions_boundary = local.boundary_arn
  assume_role_policy   = local.ecs_tasks_trust
}

# Task role of the admin task, which an operator runs with
# --enable-execute-command; ECS Exec needs the SSM message channels.
resource "aws_iam_role" "admin_task" {
  name                 = "${local.name}-admin-task"
  permissions_boundary = local.boundary_arn
  assume_role_policy   = local.ecs_tasks_trust
}

resource "aws_iam_role_policy" "admin_task_exec" {
  name = "${local.name}-admin-task-exec"
  role = aws_iam_role.admin_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "EcsExec"
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]
      Resource = "*"
    }]
  })
}
