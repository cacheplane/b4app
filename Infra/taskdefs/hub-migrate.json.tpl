[
  {
    "name": "migrate",
    "image": "${image}",
    "essential": true,
    "command": ["migrate"],
    "environment": [
      { "name": "B4HUB_LOG", "value": "info" }
    ],
    "secrets": [
      { "name": "DATABASE_ADMIN_URL", "valueFrom": "${db_admin_url_secret_arn}" },
      { "name": "DATABASE_URL", "valueFrom": "${db_url_secret_arn}" }
    ],
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
        "awslogs-stream-prefix": "migrate"
      }
    }
  }
]
