#!/usr/bin/env bash
# Runs the hub's migration task once and exits with its container's exit code.
#
# usage: run-migrate.sh <cluster> <taskdef-arn> <subnets-csv> <security-group>
#          <log-group> <log-stream-prefix> [--public-ip ENABLED|DISABLED]
#
# The task runs under its task definition's own execution and task roles. The
# log stream is <log-stream-prefix>/<container>/<task-id>, the awslogs
# driver's naming; the last 200 lines are printed whatever the outcome. A
# container that never reported an exit code (it failed to pull or start)
# counts as exit 1, and the task's stop reason is printed.
set -euo pipefail

die() {
  echo "run-migrate: $*" >&2
  exit 2
}

[ "$#" -ge 6 ] || die "usage: run-migrate.sh <cluster> <taskdef-arn> <subnets-csv> <security-group> <log-group> <log-stream-prefix> [--public-ip ENABLED|DISABLED]"
cluster="$1"
taskdef="$2"
subnets="$3"
security_group="$4"
log_group="$5"
stream_prefix="$6"
shift 6

public_ip=ENABLED
while [ "$#" -gt 0 ]; do
  case "$1" in
    --public-ip)
      [ "$#" -ge 2 ] || die "--public-ip needs a value"
      public_ip="$2"
      shift 2
      ;;
    *) die "unknown flag: $1" ;;
  esac
done
case "$public_ip" in
  ENABLED | DISABLED) ;;
  *) die "--public-ip must be ENABLED or DISABLED" ;;
esac

echo "starting the migration task ($taskdef) in $cluster"
started="$(aws ecs run-task \
  --cluster "$cluster" \
  --task-definition "$taskdef" \
  --launch-type FARGATE \
  --count 1 \
  --started-by b4hub-deploy \
  --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$security_group],assignPublicIp=$public_ip}" \
  --output json)"
task_arn="$(jq -r '.tasks[0].taskArn // ""' <<< "$started")"
if [ -z "$task_arn" ]; then
  echo "run-migrate: the task did not start:" >&2
  jq -r '.failures[]? | "  \(.arn // "-"): \(.reason // "unknown")\(if .detail then " (" + .detail + ")" else "" end)"' <<< "$started" >&2
  exit 1
fi
task_id="${task_arn##*/}"
echo "task $task_id started; waiting for it to stop"

# The waiter gives up after 10 minutes; a migration still running then is
# waited on twice more before the deploy is abandoned.
stopped=false
for _ in 1 2 3; do
  if aws ecs wait tasks-stopped --cluster "$cluster" --tasks "$task_arn"; then
    stopped=true
    break
  fi
done

described="$(aws ecs describe-tasks --cluster "$cluster" --tasks "$task_arn" --output json)"
container="$(jq -r '.tasks[0].containers[0].name // "migrate"' <<< "$described")"
exit_code="$(jq -r '.tasks[0].containers[0].exitCode // ""' <<< "$described")"
reason="$(jq -r '.tasks[0].stoppedReason // "none"' <<< "$described")"

echo "---- $log_group $stream_prefix/$container/$task_id (last 200 lines)"
if logs="$(aws logs get-log-events \
  --log-group-name "$log_group" \
  --log-stream-name "$stream_prefix/$container/$task_id" \
  --limit 200 \
  --no-start-from-head \
  --output json 2> /dev/null)"; then
  jq -r '.events[].message' <<< "$logs"
else
  echo "(no log stream: the container may never have started)"
fi
echo "----"

if [ "$stopped" != true ]; then
  echo "run-migrate: task $task_id did not stop within 30 minutes; it is still running" >&2
  exit 1
fi
case "$exit_code" in
  "" | *[!0-9]*)
    echo "run-migrate: the migration container reported no exit code; stop reason: $reason" >&2
    exit 1
    ;;
esac
echo "migration exited $exit_code (stop reason: $reason)"
exit "$exit_code"
