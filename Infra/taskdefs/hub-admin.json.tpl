[
  {
    "name": "hub",
    "image": "${image}",
    "essential": false,
    "command": ["serve"],
    "environment": [
      { "name": "B4HUB_PORT", "value": "8081" },
      { "name": "B4HUB_LOG", "value": "info" },
%{ if include_signin_secrets ~}
      { "name": "B4HUB_APPLE_AUDIENCES", "value": "com.cacheplane.b4app.ios,com.cacheplane.b4app.signin" },
%{ endif ~}
      { "name": "B4HUB_WEBAUTHN_RP_ID", "value": "${rp_id}" }
    ],
    "secrets": [
%{ if include_signin_secrets ~}
      { "name": "B4HUB_SECRET_KEY", "valueFrom": "${secret_key_arn}" },
      { "name": "B4HUB_APPLE_TEAM_ID", "valueFrom": "${apple_team_id_arn}" },
      { "name": "B4HUB_APPLE_KEY_ID", "valueFrom": "${apple_key_id_arn}" },
      { "name": "B4HUB_APPLE_PRIVATE_KEY", "valueFrom": "${apple_private_key_arn}" },
%{ endif ~}
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
    "essential": true,
    "command": ["sleep", "infinity"],
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
