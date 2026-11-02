#!/usr/bin/env bash
# Smoke-tests the production Compose profile against one image: brings the stack up with random
# secrets in a scratch copy, checks /readyz, the migrate exit code, and that `hub` never sees the
# admin URL, then tears everything down. Usage: test.sh <image-ref>
# Needs docker with Compose v2, curl, openssl. Uses 127.0.0.1:${B4HUB_LOCAL_PORT:-18080}.
set -euo pipefail

image="${1:?usage: test.sh <image-ref>}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
project="b4hub-smoke-$$"
port="${B4HUB_LOCAL_PORT:-18080}"

compose() {
  docker compose -p "$project" -f "$work/compose.yaml" -f "$work/compose.local.yaml" --env-file "$work/.env" "$@"
}

cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "--- failed (exit $status); container state and logs ---" >&2
    compose ps -a >&2 || true
    compose logs --no-color --tail 40 >&2 || true
  fi
  compose down -v --remove-orphans >&2 || true
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

cp "$here/compose.yaml" "$here/compose.local.yaml" "$here/Caddyfile" "$work/"
mkdir "$work/secrets"
umask 077
pg="$(openssl rand -hex 24)"
app="$(openssl rand -hex 24)"
printf '%s' "$pg" > "$work/secrets/postgres_password"
printf 'postgres://postgres:%s@db:5432/b4hub' "$pg" > "$work/secrets/database_admin_url"
printf 'postgres://b4hub_app:%s@db:5432/b4hub' "$app" > "$work/secrets/database_url"
chmod 0644 "$work"/secrets/*   # containers run as other uids; the files live in a throwaway dir
cat > "$work/.env" <<ENV
B4HUB_IMAGE=$image
B4HUB_VERSION=unused-when-B4HUB_IMAGE-is-set
B4HUB_PUBLIC_URL=http://localhost:$port
B4HUB_WEBAUTHN_RP_ID=localhost
B4HUB_SIGNUP=closed
CADDY_HOSTNAME=localhost
B4HUB_LOCAL_PORT=$port
ENV

compose up -d --wait --wait-timeout 180

body="$(curl -fsS "http://127.0.0.1:$port/readyz")"
echo "readyz: $body"
case "$body" in *minClientProtocol*) ;; *) echo "readyz lacks minClientProtocol" >&2; exit 1 ;; esac

migrate_state="$(compose ps -a --format '{{.Service}} {{.State}} {{.ExitCode}}' | grep '^migrate ' || true)"
echo "migrate: $migrate_state"
[ "$migrate_state" = "migrate exited 0" ] || { echo "migrate did not exit 0" >&2; exit 1; }

hub_id="$(compose ps -q hub)"
hub_env="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$hub_id")"
if grep -q '^DATABASE_ADMIN_URL' <<<"$hub_env"; then
  echo "hub container has DATABASE_ADMIN_URL*" >&2
  exit 1
fi
grep -q '^DATABASE_URL_FILE=' <<<"$hub_env" || { echo "hub lacks DATABASE_URL_FILE" >&2; exit 1; }
if docker inspect --format '{{json .HostConfig.PortBindings}}' "$hub_id" | grep -q '"HostIp":"0.0.0.0"'; then
  echo "hub publishes on all interfaces" >&2
  exit 1
fi

echo "compose smoke test passed"
