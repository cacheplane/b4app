#!/bin/sh
# Exercise the real shared shell and iOS sync banner in an isolated fixture app, without accounts,
# Keychain access, network traffic, or modifying the owner's installed app. Requires XcodeGen.
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/iOSLayout
xcodegen generate --spec Tests/iOSLayout/project.yml --project .build/iOSLayout >/dev/null
if [ -n "${B4APP_LAYOUT_DESTINATION:-}" ]; then
  destination=$B4APP_LAYOUT_DESTINATION
else
  device=$(xcrun simctl list devices available --json | python3 -c '
import json, re, sys
devices = [d for runtime, group in json.load(sys.stdin)["devices"].items()
           if (version := re.search(r"\.iOS-(\d+)", runtime)) and int(version[1]) >= 26
           for d in group if d.get("isAvailable") and d["name"].startswith("iPhone")]
devices.sort(key=lambda d: d["state"] != "Booted")
if not devices:
    raise SystemExit("No available iPhone Simulator; install an iOS runtime in Xcode.")
print(devices[0]["udid"])
')
  # Boot it and wait for the boot to finish before xcodebuild builds the harness. Left to
  # xcodebuild, a cold Simulator is still settling when the first tests run: on a hosted runner the
  # first two then failed to set the orientation and to launch the app (run 42770467156).
  xcrun simctl bootstatus "$device" -b >/dev/null
  destination="platform=iOS Simulator,id=$device"
fi
results=${B4APP_LAYOUT_RESULTS:-"$PWD/.build/iOSLayout/Results-$(date -u +%Y%m%dT%H%M%S).xcresult"}
if xcodebuild test -quiet -project .build/iOSLayout/WorkspaceLayout.xcodeproj -scheme WorkspaceLayout \
  -destination "$destination" -parallel-testing-enabled NO \
  -derivedDataPath "${B4APP_LAYOUT_DERIVED_DATA:-.build/iOSLayout/DerivedData}" \
  -resultBundlePath "$results" "$@"; then
  xcrun xcresulttool get test-results summary --path "$results" --compact > "$results.summary.json"
  python3 -c '
import json, sys
summary = json.load(open(sys.argv[1]))
print(json.dumps(summary))
if summary.get("totalTestCount", 0) == 0 or summary.get("result") != "Passed":
    raise SystemExit("Layout verification did not execute a passing test suite.")
' "$results.summary.json"
else
  result=$?
  if [ -d "$results" ]; then
    xcrun xcresulttool get test-results summary --path "$results" --compact || true
  fi
  exit "$result"
fi
