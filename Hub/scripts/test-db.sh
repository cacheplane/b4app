#!/bin/sh
# Start a throwaway PostgreSQL cluster for the hub's tests and print the environment to use it:
#
#   cd Hub && source <(./scripts/test-db.sh) && cargo test --workspace --locked
#   ./scripts/test-db.sh --stop
#
# Uses the server fetched by ./Scripts/fetch-postgres.sh (.build/postgres) and trusts every local
# connection. Each checkout (the main one and every worktree) gets its own cluster, so one
# checkout's `--stop` or tests never reach another's: the data lives under
# $TMPDIR/b4hub-test-<n>, where <n> is a checksum of the checkout's path, and the server listens on
# 127.0.0.1 only, on a port derived from the same checksum (54400 to 55399). The port is recorded
# in the data directory; if another program holds it when the cluster starts, the next free port is
# taken and recorded instead.
#
# `#[sqlx::test]` creates a fresh database per test from the printed DATABASE_URL, named after the
# test's path: two processes running the same test against one cluster drop each other's database,
# so run one `cargo test` per checkout at a time. Everything except the final `export` line goes to
# stderr so the output is safe to `source`.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PG="$ROOT/.build/postgres/bin"
BASE="${TMPDIR:-/tmp}"
SUM="$(printf '%s' "$ROOT" | cksum | cut -d ' ' -f 1)"
DIR="${BASE%/}/b4hub-test-$SUM"
PORT_FILE="$DIR/port"

if [ "${1:-}" = "--stop" ]; then
  if [ -d "$DIR/data" ]; then
    "$PG/pg_ctl" -D "$DIR/data" stop -m fast >&2 || true
  fi
  exit 0
fi

if [ ! -x "$PG/postgres" ]; then
  echo "no PostgreSQL in $ROOT/.build/postgres; run ./Scripts/fetch-postgres.sh first" >&2
  exit 1
fi

mkdir -p "$DIR"
if [ ! -f "$DIR/data/PG_VERSION" ]; then
  "$PG/initdb" -D "$DIR/data" -U postgres --auth=trust -E UTF8 --locale=C >&2
fi

in_use() {
  nc -z 127.0.0.1 "$1" >/dev/null 2>&1
}

if "$PG/pg_ctl" -D "$DIR/data" status >/dev/null 2>&1; then
  PORT="$(cat "$PORT_FILE")"
else
  if [ -f "$PORT_FILE" ]; then
    PORT="$(cat "$PORT_FILE")"
  else
    PORT=$((54400 + SUM % 1000))
  fi
  # Another checkout's cluster (or anything else) may hold the port; take the next free one.
  tries=0
  while in_use "$PORT"; do
    tries=$((tries + 1))
    if [ "$tries" -ge 1000 ]; then
      echo "no free port between 54400 and 55399" >&2
      exit 1
    fi
    PORT=$((54400 + (PORT - 54400 + 1) % 1000))
  done
  echo "$PORT" >"$PORT_FILE"
  # The socket directory stays under $TMPDIR (a Unix socket path is limited to 104 bytes); the
  # tests connect over TCP on loopback.
  "$PG/pg_ctl" -D "$DIR/data" -l "$DIR/postgres.log" -w \
    -o "-c listen_addresses=127.0.0.1 -c port=$PORT -c unix_socket_directories=$DIR -c fsync=off -c max_connections=200" \
    start >&2
fi

echo "export DATABASE_URL=postgres://postgres@127.0.0.1:$PORT/postgres"
