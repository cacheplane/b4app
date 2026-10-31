#!/bin/sh
# A stand-in for the Node executable in managed-server tests: `--version` reports a Node 24, and any
# other invocation runs its first argument (the project's "dist/index.js", really fake-b4-cli.py) with
# python3. Never a substitute for Node in anything the docs call live-tested.
if [ "$1" = "--version" ]; then
  echo "v24.0.0"
  exit 0
fi
exec python3 -I "$@"
