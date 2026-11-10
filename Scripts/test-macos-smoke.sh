#!/bin/sh
# Desktop recovery: real UI/coordinator, fake archived runtime or real B4/simulated model, private data.
set -eu
cd "$(dirname "$0")/.."
smoke_node=$(command -v node)
"$smoke_node" -e 'if (Number(process.versions.node.split(".")[0]) < 24) throw new Error("B4 smoke tests require Node 24 or newer")'
npm ci --prefix Tests/B4Runtime --ignore-scripts --no-audit --no-fund
./Scripts/fetch-postgres.sh
mkdir -p .build/macOSSmoke
xcodegen generate --spec Tests/macOSSmoke/project.yml --project .build/macOSSmoke >/dev/null
results=${B4APP_SMOKE_RESULTS:-"$PWD/.build/macOSSmoke/Results-$(date -u +%Y%m%dT%H%M%S).xcresult"}
if xcodebuild test -quiet -project .build/macOSSmoke/WorkspaceSmoke.xcodeproj -scheme WorkspaceSmoke \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -collect-test-diagnostics never \
  -derivedDataPath "${B4APP_SMOKE_DERIVED_DATA:-.build/macOSSmoke/DerivedData}" \
  -resultBundlePath "$results" "B4APP_SMOKE_NODE_PATH=$smoke_node" "$@"; then
  xcrun xcresulttool get test-results summary --path "$results" --compact > "$results.summary.json"
  python3 -c '
import json, sys
summary = json.load(open(sys.argv[1]))
print(json.dumps(summary))
if summary.get("totalTestCount", 0) == 0 or summary.get("result") != "Passed":
    raise SystemExit("macOS smoke verification did not execute a passing test suite.")
' "$results.summary.json"
else
  result=$?
  if [ -d "$results" ]; then
    xcrun xcresulttool get test-results summary --path "$results" --compact || true
  fi
  exit "$result"
fi
