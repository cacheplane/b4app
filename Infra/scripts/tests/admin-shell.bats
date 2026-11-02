#!/usr/bin/env bats
# Tests for admin-shell.sh with aws and session-manager-plugin stubbed on PATH.
# The stubs are written per test into $BATS_TEST_TMPDIR/bin; every aws call is
# appended to $STUB_LOG.

load helpers

setup() {
  root="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  script="$root/Infra/scripts/admin-shell.sh"
  stubdir="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stubdir"
  export STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
  export AWS_REGION=us-east-2
  export B4HUB_ADMIN_POLL_SECONDS=0
  : > "$STUB_LOG"
  # STUB_SERVICE_IMAGE is the hub image of the service's current revision;
  # unset, the service runs Terraform's placeholder (before the first deploy).
  cat > "$stubdir/aws" << 'STUB'
#!/usr/bin/env bash
printf 'aws %s\n' "$*" >> "${STUB_LOG:?}"
arg() { # value following flag $1
  local want="$1"; shift
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "$want" ]; then printf '%s' "${2:-}"; return 0; fi
    shift
  done
  return 1
}
acct=123456789012
case "${1:-} ${2:-}" in
  "ecs describe-task-definition")
    td="$(arg --task-definition "$@")"
    case "$td" in
      b4hub-*-hub-admin)
        env="${td#b4hub-}"; env="${env%%-*}"
        printf '{"taskDefinition":{"taskDefinitionArn":"arn:aws:ecs:us-east-2:%s:task-definition/%s:3","executionRoleArn":"arn:aws:iam::%s:role/b4hub-%s-task-exec","taskRoleArn":"arn:aws:iam::%s:role/b4hub-%s-admin-task","containerDefinitions":[{"name":"hub","image":"ghcr.io/cacheplane/b4hub:main"},{"name":"psql","image":"public.ecr.aws/docker/library/postgres:17"}]}}\n' \
          "$acct" "$td" "$acct" "$env" "$acct" "$env" ;;
      arn:aws:ecs:*:task-definition/b4hub-*-hub:*)
        printf '{"taskDefinition":{"taskDefinitionArn":"%s","containerDefinitions":[{"name":"hub","image":"%s"}]}}\n' \
          "$td" "${STUB_SERVICE_IMAGE:-ghcr.io/cacheplane/b4hub:main}" ;;
      *) echo "aws stub: unexpected task definition $td" >&2; exit 64 ;;
    esac ;;
  "ecs describe-services")
    cluster="$(arg --cluster "$@")"
    echo "arn:aws:ecs:us-east-2:$acct:task-definition/$cluster-hub:5" ;;
  "ecs register-task-definition")
    [ "${STUB_REGISTER_FAIL:-0}" = 1 ] && { echo "register refused" >&2; exit 1; }
    file="$(arg --cli-input-json "$@")"; file="${file#file://}"
    family="$(jq -er .family "$file")"
    cp "$file" "${STUB_LOG%/*}/registered-$family.json"
    printf '{"taskDefinition":{"taskDefinitionArn":"arn:aws:ecs:us-east-2:%s:task-definition/%s:4"}}\n' "$acct" "$family" ;;
  "rds describe-db-instances")
    id="$(arg --db-instance-identifier "$@")"
    printf '{"DBInstances":[{"Endpoint":{"Address":"%s.abc.us-east-2.rds.amazonaws.com"},"MasterUserSecret":{"SecretArn":"arn:aws:secretsmanager:us-east-2:%s:secret:rds!db-1234-AbC123"}}]}\n' "$id" "$acct" ;;
  "secretsmanager describe-secret")
    id="$(arg --secret-id "$@")"
    printf '{"ARN":"arn:aws:secretsmanager:us-east-2:%s:secret:%s-AbC123"}\n' "$acct" "$id" ;;
  "ec2 describe-security-groups") echo "sg-admin" ;;
  "ec2 describe-subnets") printf 'subnet-a\tsubnet-b\n' ;;
  "ecs run-task")
    if [ "${STUB_RUN_FAIL:-0}" = 1 ]; then echo None; else
      echo "arn:aws:ecs:us-east-2:$acct:task/b4hub-test/0123abcd"; fi ;;
  "ecs wait") ;;
  "ecs describe-tasks") echo RUNNING ;;
  "ecs execute-command") exit "${STUB_EXEC_EXIT:-0}" ;;
  "ecs stop-task") ;;
  *) echo "aws stub: unexpected call: $*" >&2; exit 64 ;;
esac
STUB
  printf '#!/bin/sh\nexit 0\n' > "$stubdir/session-manager-plugin"
  chmod +x "$stubdir/aws" "$stubdir/session-manager-plugin"
  export PATH="$stubdir:$PATH"
}

line_of() { grep -n -m1 -- "$1" "$STUB_LOG" | cut -d: -f1; }

@test "run-task, then wait, then execute-command, then stop-task" {
  run "$script" test
  [ "$status" -eq 0 ]
  run_at="$(line_of 'aws ecs run-task')"
  wait_at="$(line_of 'aws ecs wait tasks-running')"
  exec_at="$(line_of 'aws ecs execute-command')"
  stop_at="$(line_of 'aws ecs stop-task')"
  [ -n "$run_at" ]
  [ -n "$wait_at" ]
  [ -n "$exec_at" ]
  [ -n "$stop_at" ]
  [ "$run_at" -lt "$wait_at" ]
  [ "$wait_at" -lt "$exec_at" ]
  [ "$exec_at" -lt "$stop_at" ]
}

@test "the task runs the latest hub-admin definition in the admin group and public subnets" {
  run "$script" test
  [ "$status" -eq 0 ]
  logged 'aws ecs describe-task-definition --task-definition b4hub-test-hub-admin'
  logged 'group-name,Values=b4hub-test-admin'
  logged 'Name=tag:Name,Values=b4hub-test-public-'
  logged 'aws ecs run-task --cluster b4hub-test --task-definition arn:aws:ecs:us-east-2:123456789012:task-definition/b4hub-test-hub-admin:3'
  logged '--enable-execute-command'
  logged '--launch-type FARGATE'
  logged 'subnets=\[subnet-a,subnet-b\],securityGroups=\[sg-admin\],assignPublicIp=ENABLED'
}

deployed=123456789012.dkr.ecr.us-east-2.amazonaws.com/b4hub@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

@test "the image the service runs is registered as a new hub-admin revision and run" {
  export STUB_SERVICE_IMAGE="$deployed"
  run "$script" test
  [ "$status" -eq 0 ]
  logged "aws ecs describe-services --cluster b4hub-test --services b4hub-test-hub --query services\[0\].taskDefinition"
  logged 'aws ecs describe-task-definition --task-definition arn:aws:ecs:us-east-2:123456789012:task-definition/b4hub-test-hub:5'
  register_at="$(line_of 'aws ecs register-task-definition')"
  run_at="$(line_of 'aws ecs run-task')"
  [ -n "$register_at" ]
  [ "$register_at" -lt "$run_at" ]
  logged 'aws ecs run-task --cluster b4hub-test --task-definition arn:aws:ecs:us-east-2:123456789012:task-definition/b4hub-test-hub-admin:4'
  output_lacks "::warning::"
  doc="$BATS_TEST_TMPDIR/registered-b4hub-test-hub-admin.json"
  [ "$(jq -r .family "$doc")" = b4hub-test-hub-admin ]
  [ "$(jq -r '.containerDefinitions[] | select(.name == "hub") | .image' "$doc")" = "$deployed" ]
  [ "$(jq -r '.containerDefinitions[] | select(.name == "psql") | .image' "$doc")" = public.ecr.aws/docker/library/postgres:17 ]
  [ "$(jq -r .executionRoleArn "$doc")" = arn:aws:iam::123456789012:role/b4hub-test-task-exec ]
  [ "$(jq -r .taskRoleArn "$doc")" = arn:aws:iam::123456789012:role/b4hub-test-admin-task ]
  [ "$(jq -r '.containerDefinitions[] | select(.name == "psql") | .environment[] | select(.name == "PGHOST") | .value' "$doc")" = b4hub-test.abc.us-east-2.rds.amazonaws.com ]
  [ "$(jq -r '.containerDefinitions[] | select(.name == "psql") | .secrets[0].valueFrom' "$doc")" = 'arn:aws:secretsmanager:us-east-2:123456789012:secret:rds!db-1234-AbC123:password::' ]
  # INCLUDE_SIGNIN_SECRETS=1 (Infra/taskdefs/features.env): the sign-in secrets come first.
  [ "$(jq -r '[.containerDefinitions[] | select(.name == "hub") | .secrets[].name] | join(",")' "$doc")" = B4HUB_SECRET_KEY,B4HUB_APPLE_TEAM_ID,B4HUB_APPLE_KEY_ID,B4HUB_APPLE_PRIVATE_KEY,DATABASE_ADMIN_URL,DATABASE_URL ]
  [ "$(jq -r '.containerDefinitions[] | select(.name == "hub") | .environment[] | select(.name == "B4HUB_WEBAUTHN_RP_ID") | .value' "$doc")" = test.b4.run ]
  [ "$(jq -r '.containerDefinitions[0].logConfiguration.options."awslogs-group"' "$doc")" = /b4hub/test/admin ]
}

@test "the render directory is removed after a registration and after a failed one" {
  export STUB_SERVICE_IMAGE="$deployed"
  # macOS mktemp ignores TMPDIR, so a stub creates every temp dir under one we watch.
  export RENDER_TMP="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$RENDER_TMP"
  cat > "$stubdir/mktemp" << 'STUB'
#!/usr/bin/env bash
[ "$*" = -d ] || { echo "mktemp stub: unexpected arguments: $*" >&2; exit 64; }
dir="${RENDER_TMP:?}/d.$$.$RANDOM"
mkdir "$dir" && printf '%s\n' "$dir"
STUB
  chmod +x "$stubdir/mktemp"
  run "$script" test
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$RENDER_TMP")" ]
  export STUB_REGISTER_FAIL=1
  : > "$STUB_LOG"
  run "$script" test
  [ "$status" -ne 0 ]
  not_logged 'aws ecs run-task'
  [ -z "$(ls -A "$RENDER_TMP")" ]
}

@test "a service still on the placeholder falls back to the latest revision with a warning" {
  run "$script" test
  [ "$status" -eq 0 ]
  not_logged 'aws ecs register-task-definition'
  logged 'aws ecs run-task --cluster b4hub-test --task-definition arn:aws:ecs:us-east-2:123456789012:task-definition/b4hub-test-hub-admin:3'
  output_has "::warning::"
  output_has "placeholder image"
}

@test "the psql container is the default" {
  run "$script" test
  [ "$status" -eq 0 ]
  logged 'aws ecs execute-command .*--container psql'
  logged '--command /bin/sh'
  logged '--interactive'
}

@test "hub selects the hub container" {
  run "$script" test hub
  [ "$status" -eq 0 ]
  logged 'aws ecs execute-command .*--container hub'
  not_logged '--container psql'
}

@test "prod resolves b4hub-prod names" {
  run "$script" prod
  [ "$status" -eq 0 ]
  logged 'aws ecs run-task --cluster b4hub-prod'
  logged 'b4hub-prod-hub-admin'
}

@test "the task is stopped when execute-command fails, and its status is kept" {
  export STUB_EXEC_EXIT=7
  run "$script" test
  [ "$status" -eq 7 ]
  logged 'aws ecs stop-task --cluster b4hub-test --task arn:aws:ecs:us-east-2:123456789012:task/b4hub-test/0123abcd'
}

@test "the task ARN and the stop command are printed before the shell opens" {
  run "$script" test
  output_has "arn:aws:ecs:us-east-2:123456789012:task/b4hub-test/0123abcd"
  output_has "aws ecs stop-task --cluster b4hub-test --task"
}

@test "a missing session-manager-plugin stops before any task is started" {
  rm "$stubdir/session-manager-plugin"
  # Keep only the stub dir and the system essentials, minus any real plugin.
  PATH="$stubdir:/usr/bin:/bin" run "$script" test
  [ "$status" -ne 0 ]
  output_has "session-manager-plugin"
  output_has "Session Manager plugin"
  not_logged 'aws ecs run-task'
}

@test "a task that does not start is an error and nothing is stopped" {
  export STUB_RUN_FAIL=1
  run "$script" test
  [ "$status" -ne 0 ]
  output_has "did not start"
  not_logged 'aws ecs stop-task'
  not_logged 'aws ecs execute-command'
}

@test "bad arguments are refused" {
  run "$script"
  [ "$status" -eq 2 ]
  run "$script" staging
  [ "$status" -eq 2 ]
  run "$script" test nginx
  [ "$status" -eq 2 ]
  not_logged 'aws ecs run-task'
}
