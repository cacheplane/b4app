[
  {
    "name": "hub",
    "image": "${image}",
    "essential": true,
    "command": ["serve"],
    "environment": [
      { "name": "B4HUB_PORT", "value": "8081" },
      { "name": "B4HUB_LOG", "value": "info" }
    ],
    "secrets": [
      { "name": "DATABASE_ADMIN_URL", "valueFrom": "${db_admin_url_secret_arn}" },
      { "name": "DATABASE_URL", "valueFrom": "${db_url_secret_arn}" }
    ],
    "linuxParameters": { "initProcessEnabled": true },
    "readonlyRootFilesystem": true,
    "mountPoints": [
      { "sourceVolume": "tmp", "containerPath": "/tmp", "readOnly": false }
    ],
    "stopTimeout": 60,
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "${log_group}",
        "awslogs-region": "${region}",
        "awslogs-stream-prefix": "admin"
      }
    }
  },
  {
    "name": "psql",
    "image": "${psql_image}",
    "essential": false,
    "command": ["sleep", "3600"],
    "environment": [
      { "name": "PGHOST", "value": "${db_host}" },
      { "name": "PGPORT", "value": "5432" },
      { "name": "PGUSER", "value": "b4hub_master" },
      { "name": "PGSSLMODE", "value": "require" },
      { "name": "PGDATABASE", "value": "postgres" }
    ],
    "secrets": [
      { "name": "PGPASSWORD", "valueFrom": "${db_master_secret_arn}:password::" }
    ],
    "linuxParameters": { "initProcessEnabled": true },
    "stopTimeout": 60,
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "${log_group}",
        "awslogs-region": "${region}",
        "awslogs-stream-prefix": "admin"
      }
    }
  }
]
