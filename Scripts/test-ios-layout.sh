#!/bin/sh
# Exercise the real shared shell and iOS sync banner in an isolated fixture app, without accounts,
# Keychain access, network traffic, or modifying the owner's installed app. Requires XcodeGen.
set -eu
if [ -n "${CI:-}" ] && [ "${B4APP_LAYOUT_FOCUSED_COVERAGE:-0}" = 1 ]; then
  echo "Focused UI coverage is local-only; CI requires the full contract" >&2
  exit 2
fi
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
  destination="platform=iOS Simulator,id=$device"
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
  python3 Scripts/verify_ios_layout_results.py "$results.summary.json" "$results.tests.json" \
    --result-bundle "$results" ${focused_flag:+"$focused_flag"} \
    --ui-count "${B4APP_LAYOUT_EXPECTED_UI_TESTS:-13}" \
    --component-count "${B4APP_LAYOUT_EXPECTED_COMPONENT_TESTS:-3}"
else
  result=$?
  if [ -d "$results" ]; then
    xcrun xcresulttool get test-results summary --path "$results" --compact || true
  fi
  exit "$result"
fi
