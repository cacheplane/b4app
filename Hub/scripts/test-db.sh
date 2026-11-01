#!/bin/sh
# Start a throwaway PostgreSQL cluster for the hub's tests and print the environment to use it:
#
#   cd Hub && source <(./scripts/test-db.sh) && cargo test --workspace --locked
#   ./scripts/test-db.sh --stop
#
# Uses the server fetched by ./Scripts/fetch-postgres.sh (.build/postgres), keeps the data under
# $TMPDIR/b4hub-test, trusts every local connection, and listens on 127.0.0.1:54329 only.
# `#[sqlx::test]` creates a fresh database per test from the printed DATABASE_URL. Everything
# except the final `export` line goes to stderr so the output is safe to `source`.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PG="$ROOT/.build/postgres/bin"
BASE="${TMPDIR:-/tmp}"
DIR="${BASE%/}/b4hub-test"
PORT=54329

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

if ! "$PG/pg_ctl" -D "$DIR/data" status >/dev/null 2>&1; then
  # The socket directory stays under $TMPDIR (a Unix socket path is limited to 104 bytes); the
  # tests connect over TCP on loopback.
  "$PG/pg_ctl" -D "$DIR/data" -l "$DIR/postgres.log" -w \
    -o "-c listen_addresses=127.0.0.1 -c port=$PORT -c unix_socket_directories=$DIR -c fsync=off -c max_connections=200" \
    start >&2
fi

echo "export DATABASE_URL=postgres://postgres@127.0.0.1:$PORT/postgres"
