#!/usr/bin/env bash
# Deploys one hub image, by digest, to one environment.
#
# usage: deploy.sh <test|production> <sha256:digest>
#
# Expects AWS credentials for that environment's deploy role and docker logged
# in to both GHCR and the account's ECR registry (hub-deploy.yml does both).
# In order:
#   1. copy ghcr.io/cacheplane/b4hub@<digest> to <ecr>/b4hub:<hex> and check
#      the copy has the same digest;
#   2. resolve secret ARNs, role ARNs, and the network from the account;
#   3. render and register the hub-migrate and hub task definitions;
#   4. run the migration task; if it fails, stop: the service is not touched;
#   5. point the service at the new hub revision and wait for it to settle;
#   6. check https://<hostname>/readyz, unless the service is scaled to zero
#      (a first deploy, before runbook 4 flips desired_count), which warns.
# Any failing step stops the script. No secret value is read: only ARNs.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
taskdefs="$here/../taskdefs"
prog=deploy
# shellcheck source=Infra/scripts/taskdef-lib.sh
. "$here/taskdef-lib.sh"

die() {
  echo "deploy: $*" >&2
  exit 2
}

[ "$#" -eq 2 ] || die "usage: deploy.sh <test|production> <sha256:digest>"
case "$1" in
  test)
    env_name="test"
    hostname=hub.test.b4.run
    # Apple's web flow hands back to an https URL on the beta site (D-160),
    # which only the Beta Mac app (webcredentials:test.b4.run) takes back.
    apple_callback_name=B4HUB_APPLE_CALLBACK_URL
    apple_callback_value=https://test.b4.run/app/auth/apple
    ;;
  production | prod)
    env_name="prod"
    hostname=hub.b4.run
    # The prod app's scheme (D-140) until a prod Mac build with D-160 ships.
    apple_callback_name=B4HUB_APPLE_CALLBACK_SCHEME
    apple_callback_value=b4app
    ;;
  *) die "environment must be test or production, not '$1'" ;;
esac
digest="$2"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "digest must be sha256:<64 hex>, not '$digest'"

region="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-2}}"
export AWS_REGION="$region"
name="b4hub-$env_name"
cluster="$name"
service="$name-hub"
hub_family="$name-hub"
migrate_family="$name-hub-migrate"
source_ref="ghcr.io/cacheplane/b4hub@$digest"

signin="$(signin_flag)"
apns="$(apns_flag)"

step() { echo "==> $*"; }

[[ "$region" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]$ ]] || die "unexpected AWS region '$region'"

# 1. The image, copied by digest into this account's ECR.
account="$(resolved "account id" '^[0-9]{12}$' "$(aws sts get-caller-identity --output json | jq -r .Account)")"
registry="$(resolved "ECR registry" '^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com$' "$account.dkr.ecr.$region.amazonaws.com")"
ecr_tag="$registry/b4hub:${digest#sha256:}"
# admin-shell.sh accepts the service's image only in this shape.
image="$(resolved "ECR image reference" "$ECR_DIGEST_REF" "$registry/b4hub@$digest")"

ecr_digest() {
  docker buildx imagetools inspect "$ecr_tag" --format '{{json .Manifest}}' 2> /dev/null | jq -r '.digest // ""'
}

step "copying $source_ref to $ecr_tag"
# Tags are immutable in ECR, so a redeploy (a rollback) of a digest that is
# already there must not push again.
if existing="$(ecr_digest)" && [ -n "$existing" ]; then
  echo "already in ECR"
else
  docker buildx imagetools create --tag "$ecr_tag" "$source_ref"
fi
copied="$(ecr_digest || true)"
if [ "$copied" != "$digest" ]; then
  echo "deploy: $ecr_tag has digest '${copied:-none}', expected $digest; nothing was registered" >&2
  exit 1
fi
echo "$ecr_tag is $digest"

# 2. ARNs and network, resolved from the account (no account id in the repo).
step "resolving ARNs"
db_url_arn="$(secret_arn database-url)"
db_admin_url_arn="$(secret_arn database-admin-url)"
collect_signin_vars "$signin"
collect_apns_vars "$apns"
# The new revisions keep the roles Terraform gave each family.
hub_td="$(task_definition "$hub_family")"
hub_exec="$(resolved "$hub_family execution role" "$ARN" "$(jq -r .taskDefinition.executionRoleArn <<< "$hub_td")")"
hub_task="$(resolved "$hub_family task role" "$ARN" "$(jq -r .taskDefinition.taskRoleArn <<< "$hub_td")")"
migrate_td="$(task_definition "$migrate_family")"
migrate_exec="$(resolved "$migrate_family execution role" "$ARN" "$(jq -r .taskDefinition.executionRoleArn <<< "$migrate_td")")"
migrate_task="$(resolved "$migrate_family task role" "$ARN" "$(jq -r .taskDefinition.taskRoleArn <<< "$migrate_td")")"

services="$(aws ecs describe-services --cluster "$cluster" --services "$service" --output json)"
subnets="$(resolved "service subnets" '^subnet-[0-9a-z]+(,subnet-[0-9a-z]+)*$' "$(jq -r '.services[0].networkConfiguration.awsvpcConfiguration.subnets // [] | join(",")' <<< "$services")")"
public_ip="$(resolved "service public IP setting" '^(ENABLED|DISABLED)$' "$(jq -r '.services[0].networkConfiguration.awsvpcConfiguration.assignPublicIp // ""' <<< "$services")")"
admin_sg="$(resolved "security group $name-admin" '^sg-[0-9a-z]+$' "$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$name-admin" --output json | jq -r '.SecurityGroups[0].GroupId // ""')")"

# 3. Render and register both revisions.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

step "registering $migrate_family"
"$here/render-taskdef.sh" "$taskdefs/hub-migrate.json.tpl" "$work/migrate.json" \
  --family "$migrate_family" \
  --image "$image" \
  --region "$region" \
  --log-group "/b4hub/$env_name/migrate" \
  --exec-role "$migrate_exec" \
  --task-role "$migrate_task" \
  --include-signin-secrets "$signin" \
  --var "db_admin_url_secret_arn=$db_admin_url_arn" \
  --var "db_url_secret_arn=$db_url_arn"
migrate_arn="$(register "$work/migrate.json")"
echo "$migrate_arn"

step "registering $hub_family"
"$here/render-taskdef.sh" "$taskdefs/hub.json.tpl" "$work/hub.json" \
  --family "$hub_family" \
  --image "$image" \
  --region "$region" \
  --log-group "/b4hub/$env_name/hub" \
  --env-name "$env_name" \
  --public-url "https://$hostname" \
  --rp-id "${hostname#hub.}" \
  --exec-role "$hub_exec" \
  --task-role "$hub_task" \
  --include-signin-secrets "$signin" \
  --include-apns-secrets "$apns" \
  --var "db_url_secret_arn=$db_url_arn" \
  --var "apple_callback_name=$apple_callback_name" \
  --var "apple_callback_value=$apple_callback_value" \
  ${signin_vars[@]+"${signin_vars[@]}"} \
  ${apns_vars[@]+"${apns_vars[@]}"}
hub_arn="$(register "$work/hub.json")"
echo "$hub_arn"

# 4. Migrations first; the service is updated only if they succeed.
step "running migrations"
migrate_status=0
"$here/run-migrate.sh" "$cluster" "$migrate_arn" "$subnets" "$admin_sg" \
  "/b4hub/$env_name/migrate" migrate --public-ip "$public_ip" || migrate_status=$?
if [ "$migrate_status" -ne 0 ]; then
  echo "::error::migration failed (exit $migrate_status); the service was not updated and still runs its previous revision" >&2
  exit "$migrate_status"
fi

# 5. Roll the service.
step "updating $service to $hub_arn"
aws ecs update-service --cluster "$cluster" --service "$service" --task-definition "$hub_arn" \
  --force-new-deployment --output json > /dev/null
aws ecs wait services-stable --cluster "$cluster" --services "$service"
# The circuit breaker rolls a failed deployment back, and the rolled-back
# service is "stable" too: check the new revision is the one serving. The
# waiter can return while the rollout state still reads IN_PROGRESS (seen
# with desiredCount 0, where there is no task to wait for), so the state gets
# a bounded moment to settle before it is judged.
primary=""
desired=""
for _ in $(seq 1 "${DEPLOY_SETTLE_ATTEMPTS:-24}"); do
  settled="$(aws ecs describe-services --cluster "$cluster" --services "$service" --output json)"
  primary="$(jq -r '.services[0].deployments[] | select(.status == "PRIMARY") | "\(.taskDefinition) \(.rolloutState // "")"' <<< "$settled")"
  desired="$(resolved "service desiredCount" '^[0-9]+$' "$(jq -r '.services[0].desiredCount // ""' <<< "$settled")")"
  case "$primary" in
    *" IN_PROGRESS") sleep "${DEPLOY_SETTLE_SECONDS:-5}" ;;
    *) break ;;
  esac
done
if [ "$primary" != "$hub_arn COMPLETED" ]; then
  echo "deploy: the service settled on '${primary:-no primary deployment}', not $hub_arn COMPLETED (rolled back?)" >&2
  exit 1
fi

# 6. Readiness through the public hostname. A service scaled to zero has no
# task to answer: that is the first deploy, before runbook 4 starts one.
if [ "$desired" -eq 0 ]; then
  echo "::warning::$service has desiredCount 0, so /readyz was not checked. Runbook 4 (Infra/README.md, First deploy) sets desired_count to start the hub."
  echo "deployed $digest to $env_name (not running: desiredCount 0)"
  exit 0
fi
step "checking https://$hostname/readyz"
curl -fsS --retry 5 --retry-delay 5 --retry-all-errors --max-time 10 "https://$hostname/readyz" |
  jq -e '.minClientProtocol >= 1'
echo "deployed $digest to $env_name"
