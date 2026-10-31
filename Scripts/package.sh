#!/bin/sh
# Build the distributable macOS app (M6): the SwiftUI app plus the coordinator and the CLI inside
# Contents/Helpers and the coordinator's LaunchAgent plist, signed and zipped under dist/.
#
#   ./Scripts/package.sh                      ad hoc signature (runs on this Mac only)
#   B4APP_SIGN_IDENTITY="Developer ID Application: …" ./Scripts/package.sh
#
# The version comes from Sources/Coordinator/Version.swift so the app, the coordinator, and the CLI
# always agree. Requires Xcode 26.6 and XcodeGen.
set -eu
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*public static let current = "\(.*\)".*/\1/p' Sources/Coordinator/Version.swift)
IDENTITY="${B4APP_SIGN_IDENTITY:--}"
DERIVED=.build/DerivedData
DIST=dist
APP="$DIST/Agent Workspace.app"

echo "==> Building the coordinator and the CLI (release)"
swift build -c release --product b4app-coordinator
swift build -c release --product agent-workspace
BIN=$(swift build -c release --show-bin-path)

echo "==> Generating the Xcode project and building the app (Release, $VERSION)"
./Scripts/generate-project.sh >/dev/null
xcodebuild build -project B4App.xcodeproj -scheme B4App-macOS -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" CODE_SIGN_IDENTITY=- -quiet

echo "==> Assembling $APP"
rm -rf "$DIST"
mkdir -p "$DIST"
cp -R "$DERIVED/Build/Products/Release/Agent Workspace.app" "$APP"
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Library/LaunchAgents"
cp "$BIN/b4app-coordinator" "$BIN/agent-workspace" "$APP/Contents/Helpers/"
"$BIN/agent-workspace" coordinator plist > "$APP/Contents/Library/LaunchAgents/com.cacheplane.b4app.coordinator.plist"
plutil -lint "$APP/Contents/Library/LaunchAgents/com.cacheplane.b4app.coordinator.plist"

echo "==> Signing with identity: $IDENTITY"
if [ "$IDENTITY" = "-" ]; then
  OPTIONS=""
else
  OPTIONS="--options runtime --timestamp"
fi
# Nested code first, then the bundle; never --deep, which signs in the wrong order.
for helper in "$APP/Contents/Helpers/"*; do
  # shellcheck disable=SC2086
  codesign --force --sign "$IDENTITY" $OPTIONS "$helper"
done
# shellcheck disable=SC2086
codesign --force --sign "$IDENTITY" $OPTIONS "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

echo "==> Zipping"
ditto -c -k --keepParent "$APP" "$DIST/Agent-Workspace-$VERSION.zip"
du -sh "$APP" "$DIST/Agent-Workspace-$VERSION.zip"
if [ "$IDENTITY" = "-" ]; then
  echo "Ad hoc signature: this build runs on this Mac. Set B4APP_SIGN_IDENTITY for a Developer ID build; notarisation is a separate step (docs/milestones.md, M6)."
fi
