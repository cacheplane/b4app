#!/usr/bin/env bats
# Tests for taskdef-lib.sh's feature-flag helpers: features.env is read as
# data (one key, never sourced), and a bad value stops the caller with exit 2.

load helpers

setup() {
  root="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export PATH="$BATS_TEST_DIRNAME/stubs:$PATH"
  export STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
  export AWS_REGION=us-east-2
  : > "$STUB_LOG"
  fakedefs="$BATS_TEST_TMPDIR/taskdefs"
  mkdir -p "$fakedefs"
}

# lib <features.env body> <bash to run after sourcing the library>
lib() {
  printf '%b' "$1" > "$fakedefs/features.env"
  prog=test taskdefs="$fakedefs" bash -c ". '$root/Infra/scripts/taskdef-lib.sh'; $2"
}

@test "the checked-in features.env turns the APNs secrets off for now" {
  run bash -c "prog=test taskdefs='$root/Infra/taskdefs'; . '$root/Infra/scripts/taskdef-lib.sh'; apns_flag"
  [ "$status" -eq 0 ]
  [ "$output" = 0 ]
}

@test "apns_flag reads INCLUDE_APNS_SECRETS, 0 or 1" {
  run lib 'INCLUDE_SIGNIN_SECRETS=1\nINCLUDE_APNS_SECRETS=1\n' apns_flag
  [ "$status" -eq 0 ]
  [ "$output" = 1 ]
  run lib 'INCLUDE_SIGNIN_SECRETS=1\nINCLUDE_APNS_SECRETS=0\n' apns_flag
  [ "$status" -eq 0 ]
  [ "$output" = 0 ]
}

@test "apns_flag exits 2 on a missing or bad value" {
  for body in 'INCLUDE_SIGNIN_SECRETS=1\n' 'INCLUDE_APNS_SECRETS=2\n' 'INCLUDE_APNS_SECRETS=\n' 'INCLUDE_APNS_SECRETS=yes\n' '# INCLUDE_APNS_SECRETS=1\n'; do
    run lib "$body" apns_flag
    [ "$status" -eq 2 ]
    output_has "INCLUDE_APNS_SECRETS=0 or 1"
  done
}

@test "apns_flag never executes features.env" {
  run lib 'INCLUDE_APNS_SECRETS=1\ntouch "'"$BATS_TEST_TMPDIR"'/ran"\n' apns_flag
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/ran" ]
}

@test "the APNs and sign-in flags are independent" {
  run lib 'INCLUDE_SIGNIN_SECRETS=0\nINCLUDE_APNS_SECRETS=1\n' 'signin_flag; apns_flag'
  [ "$status" -eq 0 ]
  [ "$output" = 01 ]
}

@test "collect_apns_vars with the flag off resolves nothing" {
  run lib 'INCLUDE_APNS_SECRETS=0\n' 'collect_apns_vars 0; echo "${#apns_vars[@]}"'
  [ "$status" -eq 0 ]
  [ "$output" = 0 ]
  not_logged 'secretsmanager'
}

@test "collect_apns_vars with the flag on gives the three ARNs as --var flags" {
  run lib 'INCLUDE_APNS_SECRETS=1\n' 'collect_apns_vars 1; printf "%s\n" "${apns_vars[@]}"'
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^--var$')" -eq 3 ]
  output_has "apns_key_id_arn=arn:aws:secretsmanager:us-east-2:123456789012:secret:b4hub/apns-key-id-AbC123"
  output_has "apns_team_id_arn=arn:aws:secretsmanager:us-east-2:123456789012:secret:b4hub/apns-team-id-AbC123"
  output_has "apns_private_key_arn=arn:aws:secretsmanager:us-east-2:123456789012:secret:b4hub/apns-private-key-AbC123"
  logged 'describe-secret --secret-id b4hub/apns-private-key'
  not_logged 'get-secret-value'
}
