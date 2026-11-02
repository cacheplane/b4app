#!/usr/bin/env bash
# Renders an Infra/taskdefs/*.json.tpl container-definition template into a
# complete `aws ecs register-task-definition --cli-input-json` document.
#
# usage: render-taskdef.sh <template> <out.json>
#          --family F --exec-role ARN --task-role ARN --include-signin-secrets 0|1
#          [--image REF] [--region R] [--log-group G] [--env-name E]
#          [--public-url U] [--rp-id ID] [--var name=value ...]
#
# The named flags fill the placeholders of the same meaning (image, region,
# log_group, environment_name, public_url, rp_id); every other placeholder is
# a --var. Values are ARNs, image references, hostnames, and names only: there
# is no flag for a secret value, unknown flags are refused, and the rendered
# document is written to <out.json>, never printed.
#
# The template is processed the way Terraform's templatefile does for the
# subset these templates use: the `%{ if include_signin_secrets ~}` ...
# `%{ endif ~}` lines are kept or dropped, and each `${name}` is replaced by
# its value (JSON-escaped, since placeholders sit only inside JSON strings,
# and substituted literally, never as a regex). Anything left over exits 2.
#
# The task-definition fields around the containers match
# Infra/modules/hub/ecs.tf, so a CI revision differs from Terraform's only in
# its containers.
set -euo pipefail

usage() {
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

die() {
  echo "render-taskdef: $*" >&2
  exit 2
}

[ "$#" -ge 2 ] || usage
template="$1"
out="$2"
shift 2
[ -f "$template" ] || die "no template at $template"

family=""
exec_role=""
task_role=""
signin=""
names=()
values=()

add_var() { # name value
  local name="$1" value="$2" i
  case "$name" in
    "" | [!a-z_]* | *[!a-z0-9_]*) die "invalid placeholder name: $name" ;;
  esac
  for ((i = 0; i < ${#names[@]}; i++)); do
    [ "${names[$i]}" != "$name" ] || die "$name given twice"
  done
  names+=("$name")
  values+=("$value")
}

while [ "$#" -gt 0 ]; do
  flag="$1"
  [ "$#" -ge 2 ] || die "$flag needs a value"
  value="$2"
  shift 2
  case "$flag" in
    --family) family="$value" ;;
    --exec-role) exec_role="$value" ;;
    --task-role) task_role="$value" ;;
    --include-signin-secrets) signin="$value" ;;
    --image) add_var image "$value" ;;
    --region) add_var region "$value" ;;
    --log-group) add_var log_group "$value" ;;
    --env-name) add_var environment_name "$value" ;;
    --public-url) add_var public_url "$value" ;;
    --rp-id) add_var rp_id "$value" ;;
    --var)
      case "$value" in
        *=*) add_var "${value%%=*}" "${value#*=}" ;;
        *) die "--var takes name=value" ;;
      esac
      ;;
    *) die "unknown flag: $flag" ;;
  esac
done

[ -n "$family" ] || die "--family is required"
[ -n "$exec_role" ] || die "--exec-role is required"
[ -n "$task_role" ] || die "--task-role is required"
case "$signin" in
  0 | 1) ;;
  *) die "--include-signin-secrets must be 0 or 1" ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# 1. The one conditional block.
if ! awk -v keep="$signin" '
  /^[[:space:]]*%\{ if include_signin_secrets ~\}[[:space:]]*$/ { if (inblock) bad = 1; inblock = 1; next }
  /^[[:space:]]*%\{ endif ~\}[[:space:]]*$/ { if (!inblock) bad = 1; inblock = 0; next }
  { if (!inblock || keep == 1) print }
  END { if (inblock || bad) exit 3 }
' "$template" > "$work/stage"; then
  die "unbalanced %{ if include_signin_secrets ~} block in $template"
fi

# 2. Placeholders, one literal pass per value.
for ((i = 0; i < ${#names[@]}; i++)); do
  escaped="$(jq -rn --arg v "${values[$i]}" '$v | tojson | .[1:-1]')"
  # shellcheck disable=SC2016 # literal template markers
  case "$escaped" in
    *'${'* | *'%{'*) die "the value for ${names[$i]} contains a template marker" ;;
  esac
  RENDER_TOKEN="\${${names[$i]}}" RENDER_VALUE="$escaped" awk '
    BEGIN { token = ENVIRON["RENDER_TOKEN"]; value = ENVIRON["RENDER_VALUE"]; n = length(token) }
    {
      rest = $0; line = ""
      while ((at = index(rest, token)) > 0) {
        line = line substr(rest, 1, at - 1) value
        rest = substr(rest, at + n)
      }
      print line rest
    }
  ' "$work/stage" > "$work/next"
  mv "$work/next" "$work/stage"
done

# 3. Nothing may be left for a template engine.
# shellcheck disable=SC2016 # literal template markers
if grep -q -e '\${' -e '%{' "$work/stage"; then
  # shellcheck disable=SC2016 # literal template markers
  left="$(grep -o -e '\${[^}]*}' -e '%{[^}]*}' "$work/stage" | sort -u | paste -sd' ' -)"
  die "unresolved in $template: ${left:-template markers}"
fi
jq -e 'type == "array" and length > 0' "$work/stage" > /dev/null 2>&1 ||
  die "$template did not render to a JSON array of containers"

# 4. The task definition around the containers, as in Infra/modules/hub/ecs.tf.
jq -n \
  --slurpfile containers "$work/stage" \
  --arg family "$family" \
  --arg exec_role "$exec_role" \
  --arg task_role "$task_role" \
  '{
    family: $family,
    networkMode: "awsvpc",
    requiresCompatibilities: ["FARGATE"],
    cpu: "256",
    memory: "512",
    runtimePlatform: { cpuArchitecture: "ARM64", operatingSystemFamily: "LINUX" },
    executionRoleArn: $exec_role,
    taskRoleArn: $task_role,
    volumes: [{ name: "tmp" }],
    containerDefinitions: $containers[0]
  }' > "$work/out.json"

mv "$work/out.json" "$out"
echo "rendered $(basename "$template") as $family"
