#!/bin/sh
# Exercise the real shared shell and iOS sync banner in an isolated fixture app, without accounts,
# Keychain access, network traffic, or modifying the owner's installed app. Requires XcodeGen.
#
# Each checkout (the main one and every worktree) runs on its own Simulator, "B4App Layout <n>",
# where <n> is a checksum of the checkout's path, made on first use (an iPhone 17 Pro on the newest
# iOS 26 or later runtime). Sessions in two checkouts used to pick the same booted iPhone, and each
# run's install and launch of the harness (one bundle id) killed the other's tests. Run one layout
# suite per checkout at a time. `--stop` shuts this checkout's Simulator down and deletes it.
# B4APP_LAYOUT_DESTINATION overrides the destination.
set -eu
if [ -n "${CI:-}" ] && [ "${B4APP_LAYOUT_FOCUSED_COVERAGE:-0}" = 1 ]; then
  echo "Focused UI coverage is local-only; CI requires the full contract" >&2
  exit 2
fi
cd "$(dirname "$0")/.."
SUM="$(printf '%s' "$PWD" | cksum | cut -d ' ' -f 1)"
NAME="B4App Layout $SUM"

# The udid of this checkout's Simulator, or nothing.
own_device() {
  xcrun simctl list devices available --json | python3 -c '
import json, sys
name = sys.argv[1]
for group in json.load(sys.stdin)["devices"].values():
    for device in group:
        if device["name"] == name and device.get("isAvailable"):
            print(device["udid"])
            raise SystemExit
' "$NAME"
}

if [ "${1:-}" = "--stop" ]; then
  device=$(own_device)
  if [ -n "$device" ]; then
    xcrun simctl shutdown "$device" 2>/dev/null || true
    xcrun simctl delete "$device"
    echo "deleted $NAME ($device)"
  else
    echo "no $NAME to delete"
  fi
  exit 0
fi

mkdir -p .build/iOSLayout
xcodegen generate --spec Tests/iOSLayout/project.yml --project .build/iOSLayout >/dev/null
if [ -n "${B4APP_LAYOUT_DESTINATION:-}" ]; then
  destination=$B4APP_LAYOUT_DESTINATION
else
  device=$(own_device)
  if [ -z "$device" ]; then
    # The newest iOS 26+ runtime, and its iPhone 17 Pro (or its first iPhone when it has none).
    choice=$(xcrun simctl list runtimes available --json | python3 -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"]
            if r.get("platform") == "iOS" and r.get("isAvailable")
            and int(r["version"].split(".")[0]) >= 26]
if not runtimes:
    raise SystemExit("No iOS 26 or later Simulator runtime; install one in Xcode.")
runtime = max(runtimes, key=lambda r: [int(p) for p in r["version"].split(".")])
phones = [t for t in runtime.get("supportedDeviceTypes", []) if t.get("productFamily") == "iPhone"]
if not phones:
    raise SystemExit("The iOS %s runtime offers no iPhone." % runtime["version"])
pro = [t for t in phones if t["name"] == "iPhone 17 Pro"]
print((pro or phones)[0]["identifier"], runtime["identifier"])
')
    # shellcheck disable=SC2086 # two words: the device type and the runtime
    device=$(xcrun simctl create "$NAME" $choice)
  fi
  # Boot it and wait for the boot to finish before xcodebuild builds the harness. Left to
  # xcodebuild, a cold Simulator is still settling when the first tests run: on a hosted runner the
  # first two then failed to set the orientation and to launch the app (run 42770467156).
  xcrun simctl bootstatus "$device" -b >/dev/null
  destination="platform=iOS Simulator,id=$device"
fi
# One shard of the reviewed plan (Tests/iOSLayout/UITests/shards.json): CI runs each in its own job.
# The plan names the tests, so no caller's count or selection applies.
shard=${B4APP_LAYOUT_SHARD:-}
if [ -n "$shard" ]; then
  shard_args=$(python3 Scripts/ios_layout_shards.py xcodebuild-args "$shard")
  old_ifs=$IFS
  IFS='
'
  set -f
  for arg in $shard_args; do set -- "$@" "$arg"; done
  set +f
  IFS=$old_ifs
fi
results=${B4APP_LAYOUT_RESULTS:-"$PWD/.build/iOSLayout/Results-$(date -u +%Y%m%dT%H%M%S).xcresult"}
if xcodebuild test -quiet -project .build/iOSLayout/WorkspaceLayout.xcodeproj -scheme WorkspaceLayout \
  -destination "$destination" -parallel-testing-enabled NO \
  -derivedDataPath "${B4APP_LAYOUT_DERIVED_DATA:-.build/iOSLayout/DerivedData}" \
  -resultBundlePath "$results" "$@"; then
  xcrun xcresulttool get test-results summary --path "$results" --compact > "$results.summary.json"
  xcrun xcresulttool get test-results tests --path "$results" --compact > "$results.tests.json"
  # xcodebuild has already consumed the caller's arguments; only parser flags follow here.
  focused_flag=
  if [ "${B4APP_LAYOUT_FOCUSED_COVERAGE:-0}" = 1 ]; then focused_flag=--focused-coverage; fi
  if [ -n "$shard" ]; then
    python3 Scripts/verify_ios_layout_results.py "$results.summary.json" "$results.tests.json" \
      --result-bundle "$results" --shard "$shard"
  else
    python3 Scripts/verify_ios_layout_results.py "$results.summary.json" "$results.tests.json" \
      --result-bundle "$results" ${focused_flag:+"$focused_flag"} \
      --ui-count "${B4APP_LAYOUT_EXPECTED_UI_TESTS:-13}" \
      --component-count "${B4APP_LAYOUT_EXPECTED_COMPONENT_TESTS:-3}"
  fi
else
  result=$?
  if [ -d "$results" ]; then
    xcrun xcresulttool get test-results summary --path "$results" --compact || true
  fi
  exit "$result"
fi
