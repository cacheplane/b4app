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
  cat > "$stubdir/aws" << 'STUB'
#!/usr/bin/env bash
printf 'aws %s\n' "$*" >> "${STUB_LOG:?}"
case "${1:-} ${2:-}" in
  "ecs describe-task-definition")
    echo "arn:aws:ecs:us-east-2:123456789012:task-definition/b4hub-test-hub-admin:3" ;;
  "ec2 describe-security-groups") echo "sg-admin" ;;
  "ec2 describe-subnets") printf 'subnet-a\tsubnet-b\n' ;;
  "ecs run-task")
    if [ "${STUB_RUN_FAIL:-0}" = 1 ]; then echo None; else
      echo "arn:aws:ecs:us-east-2:123456789012:task/b4hub-test/0123abcd"; fi ;;
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
