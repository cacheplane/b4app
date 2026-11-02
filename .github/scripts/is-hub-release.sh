#!/usr/bin/env bash
# Exit 0 when the release tag is a hub release (hub-v<digit>...), 1 otherwise.
case "${1:-}" in
  hub-v[0-9]*) exit 0 ;;
  *) exit 1 ;;
esac
