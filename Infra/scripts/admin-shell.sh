#!/usr/bin/env bash
# Opens an interactive shell in a freshly started hub-admin task and stops the
# task when the shell ends.
#
# usage: admin-shell.sh <test|prod> [hub|psql]      (default: psql)
#
#   psql  the postgres:17 client; PGHOST, PGUSER=b4hub_master, and PGPASSWORD
#         (from the RDS-managed secret) are already in its environment. Used
#         once per account, for Infra/sql/bootstrap-owner.sql.
#   hub   the hub image, for `b4hub seed` and `b4hub enroll`.
#
# Run it with the owner's own credentials (the Identity Center profile, for
# example AWS_PROFILE=b4hub-test); no CI role may start this task. It needs
# the AWS CLI and the Session Manager plugin for it. No secret is read or
# printed: the task gets its secrets from ECS, and the shell is yours.
#
# The task ARN and the command that stops it are printed before the shell
# opens, so a lost terminal can still be cleaned up by hand. A trap stops the
# task on every exit path after it starts, including a failed execute-command.
set -euo pipefail

die() {
  echo "admin-shell: $*" >&2
  exit 2
}

usage="usage: admin-shell.sh <test|prod> [hub|psql]"
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || die "$usage"
case "$1" in
  test) env_name='test' ;;
  prod | production) env_name=prod ;;
  *) die "environment must be test or prod, not '$1'. $usage" ;;
esac
container="${2:-psql}"
case "$container" in
  hub | psql) ;;
  *) die "container must be hub or psql, not '$container'. $usage" ;;
esac

if ! command -v session-manager-plugin > /dev/null 2>&1; then
  {
    echo "admin-shell: the Session Manager plugin for the AWS CLI is not installed (session-manager-plugin is not on PATH)."
    echo "  macOS:  brew install --cask session-manager-plugin"
    echo "  other:  https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
  } >&2
  exit 1
fi

export AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-2}}"
name="b4hub-$env_name"
cluster="$name"
family="$name-hub-admin"
poll_seconds="${B4HUB_ADMIN_POLL_SECONDS:-2}"

# describe-task-definition on a family name returns its latest ACTIVE revision.
taskdef="$(aws ecs describe-task-definition --task-definition "$family" \
  --query 'taskDefinition.taskDefinitionArn' --output text)"
security_group="$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$name-admin" \
  --query 'SecurityGroups[0].GroupId' --output text)"
subnets="$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=$name-public-*" \
  --query 'Subnets[].SubnetId' --output text | tr -s '[:space:]' ',')"
subnets="${subnets%,}"

case "$taskdef" in arn:aws:ecs:*) ;; *) die "no active task definition for $family (got '$taskdef')" ;; esac
case "$security_group" in sg-*) ;; *) die "no security group $name-admin (got '$security_group')" ;; esac
[ -n "$subnets" ] && [ "$subnets" != None ] || die "no public subnets named $name-public-*"

echo "starting $family ($container) in $cluster"
task_arn="$(aws ecs run-task \
  --cluster "$cluster" \
  --task-definition "$taskdef" \
  --launch-type FARGATE \
  --count 1 \
  --enable-execute-command \
  --started-by "admin-shell" \
  --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$security_group],assignPublicIp=ENABLED}" \
  --query 'tasks[0].taskArn' --output text)"
case "$task_arn" in
  arn:aws:ecs:*) ;;
  *)
    echo "admin-shell: the task did not start (run-task returned '$task_arn')." >&2
    exit 1
    ;;
esac

stop_command="aws ecs stop-task --cluster $cluster --task $task_arn"
stopped=false
# shellcheck disable=SC2329 # invoked by the EXIT trap
stop_task() {
  [ "$stopped" = true ] && return 0
  stopped=true
  echo "stopping $task_arn"
  if ! aws ecs stop-task --cluster "$cluster" --task "$task_arn" --reason "admin-shell finished" > /dev/null; then
    echo "admin-shell: could not stop the task. Stop it by hand:  $stop_command" >&2
  fi
}
trap stop_task EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "task: $task_arn"
echo "if this terminal is lost, stop it with:  $stop_command"

echo "waiting for the task to run"
aws ecs wait tasks-running --cluster "$cluster" --tasks "$task_arn"

# RUNNING is not enough: ECS Exec needs the container's agent to be up.
agent=""
for _ in $(seq 1 45); do
  agent="$(aws ecs describe-tasks --cluster "$cluster" --tasks "$task_arn" \
    --query "tasks[0].containers[?name=='$container'] | [0].managedAgents[?name=='ExecuteCommandAgent'] | [0].lastStatus" \
    --output text)"
  [ "$agent" = RUNNING ] && break
  sleep "$poll_seconds"
done
[ "$agent" = RUNNING ] || die "the ECS Exec agent in container $container did not start (last status: $agent)"

echo "opening /bin/sh in $container (exit the shell to stop the task)"
status=0
aws ecs execute-command \
  --cluster "$cluster" \
  --task "$task_arn" \
  --container "$container" \
  --interactive \
  --command /bin/sh || status=$?
exit "$status"
