[
  {
    "name": "hub",
    "image": "${image}",
    "essential": true,
    "command": ["serve"],
    "portMappings": [
      { "containerPort": 8080, "protocol": "tcp" }
    ],
    "environment": [
      { "name": "B4HUB_PORT", "value": "8080" },
      { "name": "B4HUB_PUBLIC_URL", "value": "${public_url}" },
      { "name": "B4HUB_SIGNUP", "value": "open" },
      { "name": "B4HUB_WEBAUTHN_RP_ID", "value": "${rp_id}" },
      { "name": "B4HUB_APPLE_AUDIENCES", "value": "com.cacheplane.b4app.ios,com.cacheplane.b4app.signin" },
      { "name": "B4HUB_TRUST_X_FORWARDED_FOR", "value": "1" },
      { "name": "B4HUB_RETENTION_DAYS", "value": "30" },
      { "name": "B4HUB_LOG", "value": "info" }
    ],
    "secrets": [
%{ if include_signin_secrets ~}
      { "name": "B4HUB_SECRET_KEY", "valueFrom": "${secret_key_arn}" },
      { "name": "B4HUB_APPLE_TEAM_ID", "valueFrom": "${apple_team_id_arn}" },
      { "name": "B4HUB_APPLE_KEY_ID", "valueFrom": "${apple_key_id_arn}" },
      { "name": "B4HUB_APPLE_PRIVATE_KEY", "valueFrom": "${apple_private_key_arn}" },
%{ endif ~}
      { "name": "DATABASE_URL", "valueFrom": "${db_url_secret_arn}" }
    ],
    "dockerLabels": { "b4hub.environment": "${environment_name}" },
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
        "awslogs-stream-prefix": "hub"
      }
    }
  }
]
