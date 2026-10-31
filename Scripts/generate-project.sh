#!/bin/sh
# Generate B4App.xcodeproj from project.yml. Requires XcodeGen (brew install xcodegen).
set -eu
cd "$(dirname "$0")/.."
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found. Install with: brew install xcodegen" >&2
  exit 1
fi
xcodegen generate --spec project.yml
