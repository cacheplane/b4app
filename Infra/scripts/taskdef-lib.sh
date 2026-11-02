# shellcheck shell=bash disable=SC2034 # the patterns are used by the sourcing scripts
# Shared by deploy.sh and admin-shell.sh, which source it; it is not run on
# its own. It resolves what render-taskdef.sh needs from the account (ARNs,
# roles, the sign-in flag) the same way for both, and registers a rendered
# revision. Callers set `prog` (the message prefix) and `taskdefs` (the
# Infra/taskdefs directory) first. No secret value is read: only ARNs.

# Every value resolved from the account is checked for its shape before use,
# so an empty answer, "None", or an unexpected format stops the caller.
ARN='^arn:aws:[a-z0-9-]+:[a-z0-9-]*:[0-9]{0,12}:[^[:space:]]+$'
REVISION_ARN='^arn:aws:ecs:[a-z0-9-]+:[0-9]{12}:task-definition/[A-Za-z0-9_-]+:[0-9]+$'
# What deploy.sh pins every revision to: <account>.dkr.ecr.<region>.amazonaws.com/b4hub@sha256:<hex>.
ECR_DIGEST_REF='^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/b4hub@sha256:[0-9a-f]{64}$'

resolved() { # label pattern value -> value
  if ! [[ "$3" =~ $2 ]]; then
    echo "${prog:?}: could not resolve $1 (got '${3:-nothing}')" >&2
    exit 1
  fi
  printf '%s' "$3"
}

signin_flag() { # -> 0 or 1, from Infra/taskdefs/features.env
  # features.env is data, not a script: read the one key, never source it.
  local flag
  flag="$(sed -n 's/^INCLUDE_SIGNIN_SECRETS=\([01]\)[[:space:]]*$/\1/p' "${taskdefs:?}/features.env")"
  case "$flag" in
    0 | 1) printf '%s' "$flag" ;;
    *)
      echo "$prog: Infra/taskdefs/features.env must set INCLUDE_SIGNIN_SECRETS=0 or 1" >&2
      exit 2
      ;;
  esac
}

secret_arn() { # name under b4hub/ -> its ARN
  resolved "secret b4hub/$1" "$ARN" "$(aws secretsmanager describe-secret --secret-id "b4hub/$1" --output json | jq -r .ARN)"
}

task_definition() { # family or ARN -> that revision (a family: its latest ACTIVE one), as JSON
  aws ecs describe-task-definition --task-definition "$1" --output json
}

signin_vars=()
collect_signin_vars() { # 0|1 -> fills signin_vars with the four sign-in secret ARNs as --var flags
  local pair arn
  signin_vars=()
  [ "$1" = 1 ] || return 0
  for pair in secret_key_arn=secret-key apple_team_id_arn=apple-team-id \
    apple_key_id_arn=apple-key-id apple_private_key_arn=apple-private-key; do
    arn="$(secret_arn "${pair#*=}")"
    signin_vars+=(--var "${pair%%=*}=$arn")
  done
}

register() { # rendered file -> new revision ARN
  resolved "registered revision" "$REVISION_ARN" "$(aws ecs register-task-definition --cli-input-json "file://$1" --output json |
    jq -r .taskDefinition.taskDefinitionArn)"
}
