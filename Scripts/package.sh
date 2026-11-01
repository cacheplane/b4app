#!/bin/sh
# Build the distributable macOS app (M6): the SwiftUI app plus the coordinator and the CLI inside
# Contents/Helpers and the coordinator's LaunchAgent plist, signed and zipped under dist/.
#
#   ./Scripts/package.sh                      ad hoc signature (runs on this Mac only)
#   B4APP_SIGN_IDENTITY="Developer ID Application: …" ./Scripts/package.sh
#                                             signed, notarized, stapled (D-039)
#   B4APP_SKIP_NOTARIZE=1 B4APP_SIGN_IDENTITY=… ./Scripts/package.sh
#                                             Developer ID signature, nothing submitted
#
# Notarization uses the notarytool keychain profile "${B4APP_NOTARY_PROFILE:-b4app}", created once by
# the owner with `xcrun notarytool store-credentials b4app --apple-id <id> --team-id <team>`; this
# script never sees the Apple ID password. The team id is read from the identity's certificate, so
# project.yml keeps DEVELOPMENT_TEAM empty and the Xcode build itself stays ad hoc until re-signed.
#
# The version comes from Sources/Coordinator/Version.swift so the app, the coordinator, and the CLI
# always agree. Requires Xcode 26.6 and XcodeGen.
set -eu
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*public static let current = "\(.*\)".*/\1/p' Sources/Coordinator/Version.swift)
IDENTITY="${B4APP_SIGN_IDENTITY:--}"
NOTARY_PROFILE="${B4APP_NOTARY_PROFILE:-b4app}"
ENTITLEMENTS=Apps/macOS/B4App/B4App.entitlements
DERIVED=.build/DerivedData
DIST=dist
APP="$DIST/Agent Workspace.app"
ZIP="$DIST/Agent-Workspace-$VERSION.zip"

# A Developer ID identity is named by its common name or its SHA-1; either way the keychain's line
# for it carries "Developer ID Application: Name (TEAMID)". Check it, and the notary profile, before
# spending minutes on a build.
DEVELOPER_ID=0
if [ "$IDENTITY" != "-" ]; then
  IDENTITY_LINE=$(security find-identity -v -p codesigning | grep -F "$IDENTITY" | head -1 || true)
  if [ -z "$IDENTITY_LINE" ]; then
    echo "No valid code signing identity matches '$IDENTITY' (security find-identity -v -p codesigning)." >&2
    exit 1
  fi
  # Only a Developer ID name ends in the team id; "Apple Development: … (…)" carries a person id.
  case "$IDENTITY_LINE" in
    *'"Developer ID Application: '*)
      DEVELOPER_ID=1
      TEAM_ID=$(echo "$IDENTITY_LINE" | sed -n 's/.*(\([A-Z0-9]\{10\}\))"$/\1/p')
      ;;
  esac
fi
if [ "$DEVELOPER_ID" = 1 ] && [ "${B4APP_SKIP_NOTARIZE:-0}" != 1 ]; then
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "The notarytool keychain profile '$NOTARY_PROFILE' is missing or rejected. Create it yourself with:" >&2
    echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id ${TEAM_ID:-<team-id>}" >&2
    echo "or set B4APP_SKIP_NOTARIZE=1 to sign without submitting." >&2
    exit 1
  fi
fi

echo "==> Fetching the pinned PostgreSQL binaries"
./Scripts/fetch-postgres.sh

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
# The private PostgreSQL cluster's server, initdb, pg_ctl, libraries, and share tree (D-041) go
# under SharedSupport: Helpers accepts only nested code and this tree carries SQL and share files.
# The coordinator starts and stops the cluster itself; there is no second LaunchAgent.
mkdir -p "$APP/Contents/SharedSupport"
cp -R .build/postgres "$APP/Contents/SharedSupport/postgres"

echo "==> Signing with identity: $IDENTITY"
if [ "$IDENTITY" = "-" ]; then
  OPTIONS=""
else
  OPTIONS="--options runtime --timestamp"
fi
# Nested code first, then the bundle; never --deep, which signs in the wrong order. Every Mach-O in
# the PostgreSQL tree is signed individually (symlinks are skipped; their targets are signed).
find "$APP/Contents/SharedSupport/postgres" -type f \( -perm -u+x -o -name "*.dylib" \) | while read -r f; do
  if file "$f" | grep -q "Mach-O"; then
    # shellcheck disable=SC2086
    codesign --force --sign "$IDENTITY" $OPTIONS "$f" 2>&1 | grep -v "replacing existing signature" || true
  fi
done
for helper in "$APP/Contents/Helpers/b4app-coordinator" "$APP/Contents/Helpers/agent-workspace"; do
  # shellcheck disable=SC2086
  codesign --force --sign "$IDENTITY" $OPTIONS "$helper"
done
# Re-signing drops what Xcode embedded, so the bundle gets its entitlements file again.
# shellcheck disable=SC2086
codesign --force --sign "$IDENTITY" $OPTIONS --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"
if [ -n "${TEAM_ID:-}" ]; then
  SIGNED_TEAM=$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  if [ "$SIGNED_TEAM" != "$TEAM_ID" ]; then
    echo "Signed team '$SIGNED_TEAM' does not match the identity's team '$TEAM_ID'." >&2
    exit 1
  fi
  echo "Team: $TEAM_ID"
fi

echo "==> Zipping"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ "$DEVELOPER_ID" = 1 ]; then
  # Before notarization Gatekeeper reports "Unnotarized Developer ID"; shown, not required.
  spctl -a -vv --type exec "$APP" || true
  if [ "${B4APP_SKIP_NOTARIZE:-0}" = 1 ]; then
    echo "B4APP_SKIP_NOTARIZE=1: signed with $IDENTITY, not submitted for notarization."
  else
    echo "==> Notarizing with keychain profile $NOTARY_PROFILE (waits for Apple)"
    RESULT="$DIST/notarize-$VERSION.json"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait \
      --output-format json > "$RESULT" || true
    SUBMISSION=$(plutil -extract id raw -o - "$RESULT" 2>/dev/null || true)
    STATUS=$(plutil -extract status raw -o - "$RESULT" 2>/dev/null || true)
    echo "Submission: ${SUBMISSION:-none}  status: ${STATUS:-unknown}"
    if [ "$STATUS" != "Accepted" ]; then
      cat "$RESULT" >&2
      if [ -n "$SUBMISSION" ]; then
        xcrun notarytool log "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" >&2 || true
      fi
      exit 1
    fi
    echo "==> Stapling"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    # The zip that ships carries the stapled ticket, so it verifies offline.
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    ASSESSMENT=$(spctl -a -vv --type exec "$APP" 2>&1 || true)
    echo "$ASSESSMENT"
    case "$ASSESSMENT" in
      *"accepted"*"source=Notarized Developer ID"*) ;;
      *) echo "Gatekeeper did not accept the stapled app as Notarized Developer ID." >&2; exit 1 ;;
    esac
  fi
fi
du -sh "$APP" "$ZIP"
if [ "$IDENTITY" = "-" ]; then
  echo "Ad hoc signature: this build runs on this Mac. Set B4APP_SIGN_IDENTITY to a Developer ID Application identity for a notarized build (D-039)."
fi
