#!/usr/bin/env bats
# Tests for deploy.sh and run-migrate.sh with aws, docker, and curl stubbed on
# PATH (see stubs/). Every stub call is appended to $STUB_LOG.

digest=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

load helpers

setup() {
  root="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  deploy="$root/Infra/scripts/deploy.sh"
  migrate="$root/Infra/scripts/run-migrate.sh"
  export PATH="$BATS_TEST_DIRNAME/stubs:$PATH"
  export STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
  export AWS_REGION=us-east-2
  : > "$STUB_LOG"
}

line_of() { grep -n -m1 -- "$1" "$STUB_LOG" | cut -d: -f1; }

@test "a failed migration never touches the service" {
  export STUB_MIGRATE_EXIT=1
  run "$deploy" test "$digest"
  [ "$status" -ne 0 ]
  logged 'aws ecs run-task'
  not_logged 'update-service'
  not_logged 'services-stable'
  not_logged '^curl'
  output_has "service was not updated"
}

@test "a migration with no exit code counts as failed" {
  export STUB_MIGRATE_EXIT=none
  run "$deploy" test "$digest"
  [ "$status" -ne 0 ]
  not_logged 'update-service'
  output_has "CannotPullContainerError"
}

@test "a clean migration updates the service, waits, then checks readiness" {
  export STUB_MIGRATE_EXIT=0
  run "$deploy" test "$digest"
  [ "$status" -eq 0 ]
  migrate_at="$(line_of 'aws ecs run-task')"
  update_at="$(line_of 'aws ecs update-service')"
  stable_at="$(line_of 'aws ecs wait services-stable')"
  curl_at="$(line_of '^curl')"
  [ -n "$migrate_at" ]
  [ -n "$update_at" ]
  [ -n "$stable_at" ]
  [ -n "$curl_at" ]
  [ "$migrate_at" -lt "$update_at" ]
  [ "$update_at" -lt "$stable_at" ]
  [ "$stable_at" -lt "$curl_at" ]
  logged 'aws ecs update-service --cluster b4hub-test --service b4hub-test-hub --task-definition arn:aws:ecs:us-east-2:123456789012:task-definition/b4hub-test-hub:7 --force-new-deployment'
  logged 'curl .*https://hub.test.b4.run/readyz'
}

@test "the image is copied to ECR by digest and the task definitions pin it" {
  run "$deploy" test "$digest"
  [ "$status" -eq 0 ]
  logged "docker buildx imagetools create --tag 123456789012.dkr.ecr.us-east-2.amazonaws.com/b4hub:${digest#sha256:} ghcr.io/cacheplane/b4hub@$digest"
  [ "$(jq -r '.containerDefinitions[0].image' "$BATS_TEST_TMPDIR/registered-b4hub-test-hub.json")" = "123456789012.dkr.ecr.us-east-2.amazonaws.com/b4hub@$digest" ]
  [ "$(jq -r '.containerDefinitions[0].image' "$BATS_TEST_TMPDIR/registered-b4hub-test-hub-migrate.json")" = "123456789012.dkr.ecr.us-east-2.amazonaws.com/b4hub@$digest" ]
  [ "$(jq '.containerDefinitions[0].secrets | length' "$BATS_TEST_TMPDIR/registered-b4hub-test-hub.json")" -eq 1 ]
  logged 'aws ecs run-task --cluster b4hub-test --task-definition arn:aws:ecs:us-east-2:123456789012:task-definition/b4hub-test-hub-migrate:7'
  logged 'securityGroups=\[sg-admin\]'
}

@test "an image already in ECR at the same digest is not pushed again" {
  export STUB_ECR_EXISTS=1
  run "$deploy" test "$digest"
  [ "$status" -eq 0 ]
  not_logged 'imagetools create'
  logged 'register-task-definition'
}

@test "a digest mismatch after the ECR copy aborts before any registration" {
  export STUB_DIGEST_MISMATCH=1
  run "$deploy" test "$digest"
  [ "$status" -ne 0 ]
  logged 'imagetools create'
  not_logged 'register-task-definition'
  not_logged 'run-task'
  not_logged 'update-service'
}

@test "a rolled-back deployment fails before the readiness check" {
  export STUB_ROLLOUT=FAILED
  run "$deploy" test "$digest"
  [ "$status" -ne 0 ]
  logged 'update-service'
  not_logged '^curl'
}

@test "a hub below protocol 1 fails the readiness check" {
  export STUB_MIN_CLIENT_PROTOCOL=0
  run "$deploy" test "$digest"
  [ "$status" -ne 0 ]
}

@test "production deploys to the prod names and hub.b4.run" {
  run "$deploy" production "$digest"
  [ "$status" -eq 0 ]
  logged 'update-service --cluster b4hub-prod --service b4hub-prod-hub'
  logged 'curl .*https://hub.b4.run/readyz'
  logged 'describe-task-definition --task-definition b4hub-prod-hub-migrate'
}

@test "a malformed digest or environment is refused before any call" {
  run "$deploy" test sha256:abc
  [ "$status" -eq 2 ]
  run "$deploy" staging "$digest"
  [ "$status" -eq 2 ]
  [ ! -s "$STUB_LOG" ]
}

@test "run-migrate exits with the container's exit code and prints the log tail" {
  export STUB_MIGRATE_EXIT=3
  run "$migrate" b4hub-test arn:td subnet-a,subnet-b sg-admin /b4hub/test/migrate migrate
  [ "$status" -eq 3 ]
  output_has "applied 0003_organisation"
  logged 'assignPublicIp=ENABLED'
  logged 'aws ecs wait tasks-stopped --cluster b4hub-test --tasks arn:aws:ecs:us-east-2:123456789012:task/b4hub-test/0123abcd'
  logged 'log-stream-name migrate/migrate/0123abcd'
}

@test "run-migrate honours --public-ip DISABLED" {
  run "$migrate" b4hub-test arn:td subnet-a sg-admin /b4hub/test/migrate migrate --public-ip DISABLED
  [ "$status" -eq 0 ]
  logged 'assignPublicIp=DISABLED'
}
