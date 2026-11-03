#!/bin/bash
# Feed the hub's notification spool to an iOS Simulator (M8f). With B4HUB_PUSH_SENDER=spool the hub
# writes each notification as an `.apns` file (it carries the `Simulator Target Bundle` key) into
# the spool directory that Hub/compose.yaml bind-mounts at Hub/push-spool. This script polls that
# directory twice a second and pushes each finished file, oldest first, with `xcrun simctl push`.
# A pushed file moves to <dir>/sent/, a refused one to <dir>/failed/ with simctl's error printed.
# Hidden `.<name>.tmp` files are the hub's writes in progress and are ignored. Ctrl-C stops it.
#
#   ./Scripts/sim-push.sh                       # Hub/push-spool, the booted Simulator
#   ./Scripts/sim-push.sh /path/to/spool        # another spool directory
#   B4APP_SIM_DEVICE=<udid or name> ./Scripts/sim-push.sh   # when more than one Simulator is booted
set -euo pipefail

if ! xcrun --find simctl >/dev/null 2>&1; then
  echo "sim-push.sh needs xcrun simctl (install Xcode and its command line tools)" >&2
  exit 1
fi

cd "$(dirname "$0")/.."
DIR="${1:-Hub/push-spool}"
DEVICE="${B4APP_SIM_DEVICE:-booted}"
mkdir -p "$DIR/sent" "$DIR/failed"

echo "sim-push: watching $DIR, pushing to Simulator '$DEVICE' (Ctrl-C to stop)"
trap 'echo; echo "sim-push: stopped"; exit 0' INT TERM

while true; do
  # Names start with a millisecond timestamp, so the glob's sorted order is oldest first.
  for file in "$DIR"/*.apns; do
    [ -f "$file" ] || continue
    name=$(basename "$file")
    reason=$(plutil -extract reason raw "$file" 2>/dev/null) || reason="?"
    if error=$(xcrun simctl push "$DEVICE" "$file" 2>&1); then
      mv "$file" "$DIR/sent/$name"
      echo "sent    $name  $reason"
    else
      mv "$file" "$DIR/failed/$name"
      echo "failed  $name  $reason" >&2
      echo "        $error" >&2
    fi
  done
  sleep 0.5
done
