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
#   6. check https://<hostname>/readyz.
# Any failing step stops the script. No secret value is read: only ARNs.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
taskdefs="$here/../taskdefs"

die() {
  echo "deploy: $*" >&2
  exit 2
}

[ "$#" -eq 2 ] || die "usage: deploy.sh <test|production> <sha256:digest>"
case "$1" in
  test)
    env_name="test"
    hostname=hub.test.b4.run
    ;;
  production | prod)
    env_name="prod"
    hostname=hub.b4.run
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

# features.env is data, not a script: read the one key, never source it.
signin="$(sed -n 's/^INCLUDE_SIGNIN_SECRETS=\([01]\)[[:space:]]*$/\1/p' "$taskdefs/features.env")"
case "$signin" in
  0 | 1) ;;
  *) die "Infra/taskdefs/features.env must set INCLUDE_SIGNIN_SECRETS=0 or 1" ;;
esac

step() { echo "==> $*"; }

nonempty() { # label value
  case "$2" in
    "" | null | None) echo "deploy: could not resolve $1" >&2; exit 1 ;;
  esac
  printf '%s' "$2"
}

# 1. The image, copied by digest into this account's ECR.
account="$(nonempty "account id" "$(aws sts get-caller-identity --output json | jq -r .Account)")"
registry="$account.dkr.ecr.$region.amazonaws.com"
ecr_tag="$registry/b4hub:${digest#sha256:}"
image="$registry/b4hub@$digest"

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
secret_arn() {
  nonempty "secret b4hub/$1" "$(aws secretsmanager describe-secret --secret-id "b4hub/$1" --output json | jq -r .ARN)"
}
task_definition() { # family -> its current revision, as JSON
  aws ecs describe-task-definition --task-definition "$1" --output json
}

db_url_arn="$(secret_arn database-url)"
db_admin_url_arn="$(secret_arn database-admin-url)"
signin_vars=()
if [ "$signin" = 1 ]; then
  for pair in secret_key_arn=secret-key apple_team_id_arn=apple-team-id \
    apple_key_id_arn=apple-key-id apple_private_key_arn=apple-private-key; do
    arn="$(secret_arn "${pair#*=}")"
    signin_vars+=(--var "${pair%%=*}=$arn")
  done
fi
# The new revisions keep the roles Terraform gave each family.
hub_td="$(task_definition "$hub_family")"
hub_exec="$(nonempty "$hub_family execution role" "$(jq -r .taskDefinition.executionRoleArn <<< "$hub_td")")"
hub_task="$(nonempty "$hub_family task role" "$(jq -r .taskDefinition.taskRoleArn <<< "$hub_td")")"
migrate_td="$(task_definition "$migrate_family")"
migrate_exec="$(nonempty "$migrate_family execution role" "$(jq -r .taskDefinition.executionRoleArn <<< "$migrate_td")")"
migrate_task="$(nonempty "$migrate_family task role" "$(jq -r .taskDefinition.taskRoleArn <<< "$migrate_td")")"

services="$(aws ecs describe-services --cluster "$cluster" --services "$service" --output json)"
subnets="$(nonempty "service subnets" "$(jq -r '.services[0].networkConfiguration.awsvpcConfiguration.subnets // [] | join(",")' <<< "$services")")"
public_ip="$(nonempty "service public IP setting" "$(jq -r '.services[0].networkConfiguration.awsvpcConfiguration.assignPublicIp // ""' <<< "$services")")"
admin_sg="$(nonempty "security group $name-admin" "$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$name-admin" --output json | jq -r '.SecurityGroups[0].GroupId // ""')")"

# 3. Render and register both revisions.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

register() { # rendered file -> new revision ARN
  nonempty "registered revision" "$(aws ecs register-task-definition --cli-input-json "file://$1" --output json |
    jq -r .taskDefinition.taskDefinitionArn)"
}

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
  --var "db_url_secret_arn=$db_url_arn" \
  ${signin_vars[@]+"${signin_vars[@]}"}
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
# service is "stable" too: check the new revision is the one serving.
primary="$(aws ecs describe-services --cluster "$cluster" --services "$service" --output json |
  jq -r '.services[0].deployments[] | select(.status == "PRIMARY") | "\(.taskDefinition) \(.rolloutState // "")"')"
if [ "$primary" != "$hub_arn COMPLETED" ]; then
  echo "deploy: the service settled on '${primary:-no primary deployment}', not $hub_arn COMPLETED (rolled back?)" >&2
  exit 1
fi

# 6. Readiness through the public hostname.
step "checking https://$hostname/readyz"
curl -fsS --retry 5 --retry-delay 5 --retry-all-errors --max-time 10 "https://$hostname/readyz" |
  jq -e '.minClientProtocol >= 1'
echo "deployed $digest to $env_name"
