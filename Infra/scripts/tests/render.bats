#!/usr/bin/env bats
# Tests for render-taskdef.sh: the templates in Infra/taskdefs rendered into a
# complete register-task-definition document.

load helpers

setup() {
  root="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  render="$root/Infra/scripts/render-taskdef.sh"
  taskdefs="$root/Infra/taskdefs"
  out="$BATS_TEST_TMPDIR/taskdef.json"
}

arn() { printf 'arn:aws:secretsmanager:us-east-2:123456789012:secret:b4hub/%s-AbC123' "$1"; }

render_hub() { # $1 = include_signin_secrets, extra args follow
  local signin="$1"; shift
  "$render" "$taskdefs/hub.json.tpl" "$out" \
    --family b4hub-test-hub \
    --image 123456789012.dkr.ecr.us-east-2.amazonaws.com/b4hub@sha256:0123 \
    --region us-east-2 \
    --log-group /b4hub/test/hub \
    --env-name test \
    --public-url https://hub.test.b4.run \
    --rp-id test.b4.run \
    --exec-role arn:aws:iam::123456789012:role/b4hub-test-task-exec \
    --task-role arn:aws:iam::123456789012:role/b4hub-test-task \
    --include-signin-secrets "$signin" \
    --var "db_url_secret_arn=${DB_URL_ARN:-$(arn database-url)}" \
    --var "secret_key_arn=$(arn secret-key)" \
    --var "apple_team_id_arn=$(arn apple-team-id)" \
    --var "apple_key_id_arn=$(arn apple-key-id)" \
    --var "apple_private_key_arn=$(arn apple-private-key)" \
    "$@"
}

@test "without sign-in secrets the hub gets only DATABASE_URL" {
  run render_hub 0
  [ "$status" -eq 0 ]
  [ "$(jq '.containerDefinitions[0].secrets | length' "$out")" -eq 1 ]
  [ "$(jq -r '.containerDefinitions[0].secrets[0].name' "$out")" = DATABASE_URL ]
  [ "$(jq -r '.containerDefinitions[0].secrets[0].valueFrom' "$out")" = "$(arn database-url)" ]
}

@test "with sign-in secrets the hub gets five, in template order" {
  run render_hub 1
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.containerDefinitions[0].secrets[].name] | join(",")' "$out")" = \
    "B4HUB_SECRET_KEY,B4HUB_APPLE_TEAM_ID,B4HUB_APPLE_KEY_ID,B4HUB_APPLE_PRIVATE_KEY,DATABASE_URL" ]
  [ "$(jq -r '.containerDefinitions[0].secrets[3].valueFrom' "$out")" = "$(arn apple-private-key)" ]
}

@test "a placeholder with no value exits 2 and writes nothing" {
  tpl="$BATS_TEST_TMPDIR/extra.json.tpl"
  sed 's/"B4HUB_LOG", "value": "info"/"B4HUB_LOG", "value": "${unknown_thing}"/' "$taskdefs/hub.json.tpl" > "$tpl"
  grep -q 'unknown_thing' "$tpl"
  run "$render" "$tpl" "$out" --family f --image i --region r --log-group g --env-name e \
    --public-url u --rp-id p --exec-role x --task-role t --include-signin-secrets 0 \
    --var db_url_secret_arn=a
  [ "$status" -eq 2 ]
  output_has "unknown_thing"
  [ ! -e "$out" ]
}

@test "an unknown directive exits 2" {
  tpl="$BATS_TEST_TMPDIR/directive.json.tpl"
  sed 's/%{ endif ~}/%{ else ~}/' "$taskdefs/hub.json.tpl" > "$tpl"
  run "$render" "$tpl" "$out" --family f --image i --region r --log-group g --env-name e \
    --public-url u --rp-id p --exec-role x --task-role t --include-signin-secrets 1 \
    --var db_url_secret_arn=a --var secret_key_arn=a --var apple_team_id_arn=a \
    --var apple_key_id_arn=a --var apple_private_key_arn=a
  [ "$status" -eq 2 ]
}

@test "values with sed and JSON metacharacters arrive byte-identical" {
  weird='arn:aws:secretsmanager:us-east-2:1:secret:a&b=c%d/e\f\n&&\1'
  DB_URL_ARN="$weird" run render_hub 0
  [ "$status" -eq 0 ]
  [ "$(jq -r '.containerDefinitions[0].secrets[0].valueFrom' "$out")" = "$weird" ]
}

@test "the wrapped document matches what Terraform registers" {
  run render_hub 0
  [ "$status" -eq 0 ]
  [ "$(jq -r .family "$out")" = b4hub-test-hub ]
  [ "$(jq -c .volumes "$out")" = '[{"name":"tmp"}]' ]
  [ "$(jq -r .runtimePlatform.cpuArchitecture "$out")" = ARM64 ]
  [ "$(jq -r .runtimePlatform.operatingSystemFamily "$out")" = LINUX ]
  [ "$(jq -r .networkMode "$out")" = awsvpc ]
  [ "$(jq -c .requiresCompatibilities "$out")" = '["FARGATE"]' ]
  [ "$(jq -r .cpu "$out")" = 256 ]
  [ "$(jq -r .memory "$out")" = 512 ]
  [ "$(jq -r .executionRoleArn "$out")" = arn:aws:iam::123456789012:role/b4hub-test-task-exec ]
  [ "$(jq -r .taskRoleArn "$out")" = arn:aws:iam::123456789012:role/b4hub-test-task ]
  [ "$(jq -r '.containerDefinitions[0].environment[] | select(.name == "B4HUB_APPLE_SERVICES_ID") | .value' "$out")" = com.cacheplane.b4app.signin ]
  [ "$(jq -r '.containerDefinitions[0].environment[] | select(.name == "B4HUB_PUBLIC_URL") | .value' "$out")" = https://hub.test.b4.run ]
  [ "$(jq -r '.containerDefinitions[0].image' "$out")" = 123456789012.dkr.ecr.us-east-2.amazonaws.com/b4hub@sha256:0123 ]
  [ "$(jq -r '.containerDefinitions[0].dockerLabels."b4hub.environment"' "$out")" = test ]
}

@test "the migrate template renders" {
  run "$render" "$taskdefs/hub-migrate.json.tpl" "$out" --family b4hub-test-hub-migrate \
    --image img --region us-east-2 --log-group /b4hub/test/migrate \
    --exec-role x --task-role t --include-signin-secrets 0 \
    --var "db_url_secret_arn=$(arn database-url)" --var "db_admin_url_secret_arn=$(arn database-admin-url)"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.containerDefinitions[0].secrets[].name] | join(",")' "$out")" = DATABASE_ADMIN_URL,DATABASE_URL ]
  [ "$(jq -r '.containerDefinitions[0].logConfiguration.options."awslogs-group"' "$out")" = /b4hub/test/migrate ]
}

@test "the rendered document is never printed" {
  run render_hub 0
  [ "$status" -eq 0 ]
  output_lacks "secretsmanager"
  output_lacks "containerDefinitions"
}

@test "a placeholder given twice exits 2" {
  run render_hub 0 --var db_url_secret_arn=other
  [ "$status" -eq 2 ]
}

@test "unknown flags are refused, so no secret value can be passed" {
  run render_hub 0 --secret-value hunter2
  [ "$status" -eq 2 ]
  output_lacks "hunter2"
  [ ! -e "$out" ]
}

@test "a missing required flag exits 2" {
  run "$render" "$taskdefs/hub-migrate.json.tpl" "$out" --image img
  [ "$status" -eq 2 ]
}
