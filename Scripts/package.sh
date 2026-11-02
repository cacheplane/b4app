#!/bin/sh
# Build the distributable macOS app (M6): the SwiftUI app plus the CLI and the coordinator (a
# minimal app-like bundle, D-051) inside Contents/Helpers and the coordinator's LaunchAgent plist,
# signed and zipped under dist/.
#
# B4APP_FLAVOR picks the build flavour: prod (the default), beta, or local (Flavor.swift, sign-in
# plan). A flavour owns its bundle ids, LaunchAgent label, keychain group, and site domain, and is
# written into B4AppFlavor in the Info.plist of the app and of the coordinator bundle. Prod ships as
# "Agent Workspace.app" and Agent-Workspace-<version>.zip; the others as "Agent Workspace (Beta).app"
# and Agent-Workspace-Beta-<version>.zip, so the three can sit side by side.
#
#   ./Scripts/package.sh                      ad hoc signature (runs on this Mac only)
#   B4APP_SIGN_IDENTITY="Developer ID Application: …" ./Scripts/package.sh
#                                             signed, notarized, stapled (D-039)
#   B4APP_SKIP_NOTARIZE=1 B4APP_SIGN_IDENTITY=… ./Scripts/package.sh
#                                             Developer ID signature, nothing submitted
#
# A Developer ID build also embeds two Developer ID provisioning profiles, one for the app
# (App ID com.cacheplane.b4app<id suffix>) and one for the coordinator (the same plus .coordinator).
# Both need Keychain Sharing, so the two share the data-protection keychain group
# <team>.com.cacheplane.b4app<id suffix>.shared (the local flavour also claims the prod group, so it
# can read the owner's existing secrets once); the app profile also needs Associated Domains, for
# webcredentials:<site domain> (passkeys). The profiles are read from B4APP_APP_PROFILE and
# B4APP_COORDINATOR_PROFILE, by default ~/.b4app/signing/{app,coordinator}<dir suffix>.provisionprofile
# (app-beta.provisionprofile, coordinator-local.provisionprofile, …); B4APP_SKIP_PROFILES=1 signs
# without them, and the coordinator then keeps secrets in the login keychain. The entitlements are
# generated here from the certificate's team id and the flavour.
#
#   B4APP_CHECK_PROFILES_ONLY=1 B4APP_TEAM_ID=<team> ./Scripts/package.sh
#                                             only check the profiles against the flavour (with an
#                                             identity, its team id is used); builds and signs nothing
#
# Notarization uses the notarytool keychain profile "${B4APP_NOTARY_PROFILE:-b4app}", created once by
# the owner with `xcrun notarytool store-credentials b4app --apple-id <id> --team-id <team>`; this
# script never sees the Apple ID password. The team id is read from the identity's certificate, so
# no team id is committed and the Xcode build itself stays ad hoc until re-signed.
#
# The version comes from Sources/Coordinator/Version.swift so the app, the coordinator, and the CLI
# always agree. Requires Xcode 26.6 and XcodeGen.
set -eu
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*public static let current = "\(.*\)".*/\1/p' Sources/Coordinator/Version.swift)
IDENTITY="${B4APP_SIGN_IDENTITY:--}"
NOTARY_PROFILE="${B4APP_NOTARY_PROFILE:-b4app}"
ENTITLEMENTS=Apps/macOS/B4App/B4App.entitlements

# The flavour: these mirror Flavor.swift, project.yml's configurations, and Config/Flavor-*.xcconfig.
FLAVOR="${B4APP_FLAVOR:-prod}"
case "$FLAVOR" in
  prod)
    ID_SUFFIX=""; DIR_SUFFIX=""; XCODE_CONFIG=Release; SITE_DOMAIN=b4.run
    NAME_SUFFIX=""; ZIP_SUFFIX=""
    ;;
  beta)
    ID_SUFFIX=".beta"; DIR_SUFFIX="-beta"; XCODE_CONFIG=Release-Beta; SITE_DOMAIN=test.b4.run
    NAME_SUFFIX=" (Beta)"; ZIP_SUFFIX="-Beta"
    ;;
  local)
    ID_SUFFIX=".local"; DIR_SUFFIX="-local"; XCODE_CONFIG=Release-Local; SITE_DOMAIN=local.b4.run
    NAME_SUFFIX=" (Local)"; ZIP_SUFFIX="-Local"
    ;;
  *)
    echo "B4APP_FLAVOR must be prod, beta, or local, not '$FLAVOR'." >&2
    exit 1
    ;;
esac
APP_ID="com.cacheplane.b4app$ID_SUFFIX"
COORDINATOR_ID="$APP_ID.coordinator"
# The keychain groups the flavour claims, as App IDs; the local flavour also claims the prod group
# so it can read the owner's existing secrets once. The group is <team>.<id>.shared.
KEYCHAIN_IDS="$APP_ID"
if [ "$FLAVOR" = local ]; then KEYCHAIN_IDS="$APP_ID com.cacheplane.b4app"; fi
APP_PROFILE="${B4APP_APP_PROFILE:-$HOME/.b4app/signing/app$DIR_SUFFIX.provisionprofile}"
COORDINATOR_PROFILE="${B4APP_COORDINATOR_PROFILE:-$HOME/.b4app/signing/coordinator$DIR_SUFFIX.provisionprofile}"
DERIVED=.build/DerivedData
DIST=dist
APP="$DIST/Agent Workspace$NAME_SUFFIX.app"
ZIP="$DIST/Agent-Workspace$ZIP_SUFFIX-$VERSION.zip"
WRAPPER="$APP/Contents/Helpers/B4AppCoordinator.app"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/b4app-package.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

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
# keychain_groups: the groups the flavour claims, one per line, for the team being signed for.
keychain_groups() {
  for id in $KEYCHAIN_IDS; do echo "$TEAM_ID.$id.shared"; done
}

# profile_values <decoded profile> <entitlement>: the values the profile authorises, one per line.
# An array prints its elements, a string prints itself; a missing key prints nothing.
profile_values() {
  /usr/libexec/PlistBuddy -c "Print :Entitlements:$2" "$1" 2>/dev/null \
    | sed -e '/^Array {$/d' -e '/^}$/d' -e 's/^ *//' || true
}

# profile_allows <values> <value> <wildcard>: the exact value or the wildcard is one of the lines.
profile_allows() {
  printf '%s\n' "$1" | grep -Fxq -e "$2" -e "$3"
}

# check_profile <file> <bundle id> <app|coordinator>: the profile is a Developer ID profile for this
# team and App ID, unexpired, and authorises every entitlement the flavour needs: each keychain
# group, and for the app the associated domain. Names everything missing at once. Prints its expiry.
check_profile() {
  decoded="$WORK/$(basename "$1").plist"
  if ! security cms -D -i "$1" > "$decoded" 2>/dev/null; then
    echo "Cannot decode the provisioning profile $1." >&2
    exit 1
  fi
  app_identifier=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$decoded" 2>/dev/null || true)
  if [ "$app_identifier" != "$TEAM_ID.$2" ]; then
    echo "$1 is for '$app_identifier', not $TEAM_ID.$2." >&2
    exit 1
  fi
  missing=""
  groups=$(profile_values "$decoded" keychain-access-groups)
  for group in $(keychain_groups); do
    if ! profile_allows "$groups" "$group" "$TEAM_ID.*"; then
      missing="$missing
  keychain-access-groups: $group"
    fi
  done
  if [ "$3" = app ]; then
    domains=$(profile_values "$decoded" com.apple.developer.associated-domains)
    if ! profile_allows "$domains" "webcredentials:$SITE_DOMAIN" "*"; then
      missing="$missing
  com.apple.developer.associated-domains: webcredentials:$SITE_DOMAIN"
    fi
  fi
  if [ -n "$missing" ]; then
    echo "$1 does not authorise these entitlements (enable Keychain Sharing and, for the app, Associated Domains on the App ID $2, then regenerate the profile):$missing" >&2
    exit 1
  fi
  expires=$(plutil -extract ExpirationDate raw -o - "$decoded")
  if [ "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \> "$expires" ]; then
    echo "$1 expired on $expires; an app signed with it will not launch." >&2
    exit 1
  fi
  echo "Profile $(basename "$1"): $TEAM_ID.$2, expires $expires"
}

# write_entitlements <file> <bundle id> <app|coordinator>: the identity of the App ID, the keychain
# groups, and for the app the associated domain.
write_entitlements() {
  {
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.application-identifier</key><string>$TEAM_ID.$2</string>
  <key>com.apple.developer.team-identifier</key><string>$TEAM_ID</string>
  <key>keychain-access-groups</key>
  <array>
PLIST
    for group in $(keychain_groups); do echo "    <string>$group</string>"; done
    echo "  </array>"
    if [ "$3" = app ]; then
      echo "  <key>com.apple.developer.associated-domains</key>"
      echo "  <array><string>webcredentials:$SITE_DOMAIN</string></array>"
    fi
    echo "</dict>"
    echo "</plist>"
  } > "$1"
  plutil -lint "$1" >/dev/null
}

PROFILES=0
APP_ENTITLEMENTS="$ENTITLEMENTS"
COORDINATOR_ENTITLEMENTS=""
CHECK_ONLY="${B4APP_CHECK_PROFILES_ONLY:-0}"
if [ "$CHECK_ONLY" = 1 ] && [ "$DEVELOPER_ID" != 1 ]; then
  # The dry path needs a team id but signs nothing: from the identity, or given directly.
  if [ "$IDENTITY" = "-" ] && [ -n "${B4APP_TEAM_ID:-}" ]; then
    TEAM_ID="$B4APP_TEAM_ID"
    DEVELOPER_ID=1
  else
    echo "B4APP_CHECK_PROFILES_ONLY=1 needs B4APP_TEAM_ID or a Developer ID identity." >&2
    exit 1
  fi
fi
if [ "$DEVELOPER_ID" = 1 ] && { [ "${B4APP_SKIP_PROFILES:-0}" != 1 ] || [ "$CHECK_ONLY" = 1 ]; }; then
  for profile in "$APP_PROFILE" "$COORDINATOR_PROFILE"; do
    if [ ! -f "$profile" ]; then
      {
        echo "Missing provisioning profile $profile. Create Developer ID profiles at developer.apple.com, save them there or set B4APP_APP_PROFILE and B4APP_COORDINATOR_PROFILE, or set B4APP_SKIP_PROFILES=1 to keep secrets in the login keychain. For the $FLAVOR flavour:"
        echo "  App ID $APP_ID (the app's profile): Associated Domains, with the entitlement com.apple.developer.associated-domains = webcredentials:$SITE_DOMAIN"
        for group in $(keychain_groups); do echo "  App ID $APP_ID and App ID $COORDINATOR_ID: Keychain Sharing, with the group keychain-access-groups = $group"; done
      } >&2
      exit 1
    fi
  done
  check_profile "$APP_PROFILE" "$APP_ID" app
  check_profile "$COORDINATOR_PROFILE" "$COORDINATOR_ID" coordinator
  APP_ENTITLEMENTS="$WORK/app.entitlements"
  COORDINATOR_ENTITLEMENTS="$WORK/coordinator.entitlements"
  write_entitlements "$APP_ENTITLEMENTS" "$APP_ID" app
  write_entitlements "$COORDINATOR_ENTITLEMENTS" "$COORDINATOR_ID" coordinator
  PROFILES=1
fi
if [ "$CHECK_ONLY" = 1 ]; then
  if [ "$PROFILES" != 1 ]; then
    echo "B4APP_CHECK_PROFILES_ONLY=1 checked nothing; unset B4APP_SKIP_PROFILES." >&2
    exit 1
  fi
  echo "B4APP_CHECK_PROFILES_ONLY=1: the $FLAVOR flavour's profiles authorise everything it needs; nothing built or signed."
  exit 0
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

echo "==> Generating the Xcode project and building the app ($FLAVOR flavour, $XCODE_CONFIG, $VERSION)"
./Scripts/generate-project.sh >/dev/null
xcodebuild build -project B4App.xcodeproj -scheme B4App-macOS -configuration "$XCODE_CONFIG" \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" CODE_SIGN_IDENTITY=- -quiet

echo "==> Assembling $APP"
rm -rf "$DIST"
mkdir -p "$DIST"
ditto "$DERIVED/Build/Products/$XCODE_CONFIG/Agent Workspace.app" "$APP"
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Library/LaunchAgents" "$WRAPPER/Contents/MacOS"
cp "$BIN/agent-workspace" "$APP/Contents/Helpers/"
# The coordinator is a background-only app bundle so it can hold its own provisioning profile; the
# LaunchAgent runs its executable directly.
cp "$BIN/b4app-coordinator" "$WRAPPER/Contents/MacOS/"
cat > "$WRAPPER/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$COORDINATOR_ID</string>
  <key>CFBundleExecutable</key><string>b4app-coordinator</string>
  <key>CFBundleName</key><string>Agent Workspace Coordinator</string>
  <key>B4AppFlavor</key><string>$FLAVOR</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$WRAPPER/Contents/Info.plist" >/dev/null
# Flavor.current walks up from an executable to its nearest .app, so the app, the coordinator bundle,
# and with them the CLI in Helpers (inside the app) must all say the same flavour.
for bundle in "$APP" "$WRAPPER"; do
  built=$(plutil -extract B4AppFlavor raw -o - "$bundle/Contents/Info.plist" 2>/dev/null || true)
  if [ "$built" != "$FLAVOR" ]; then
    echo "$bundle has B4AppFlavor '$built', not '$FLAVOR'." >&2
    exit 1
  fi
done
built=$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")
if [ "$built" != "$APP_ID" ]; then
  echo "$APP has the bundle id '$built', not $APP_ID." >&2
  exit 1
fi
if [ "$PROFILES" = 1 ]; then
  cp "$APP_PROFILE" "$APP/Contents/embedded.provisionprofile"
  cp "$COORDINATOR_PROFILE" "$WRAPPER/Contents/embedded.provisionprofile"
fi
# The CLI runs from .build here, outside any .app, so the flavour comes from the environment.
LAUNCH_AGENT="$APP/Contents/Library/LaunchAgents/$COORDINATOR_ID.plist"
B4APP_FLAVOR="$FLAVOR" "$BIN/agent-workspace" coordinator plist > "$LAUNCH_AGENT"
plutil -lint "$LAUNCH_AGENT"
LABEL=$(plutil -extract Label raw -o - "$LAUNCH_AGENT")
if [ "$LABEL" != "$COORDINATOR_ID" ]; then
  echo "The LaunchAgent label is '$LABEL', not $COORDINATOR_ID; Flavor.swift and this script disagree." >&2
  exit 1
fi
# The private PostgreSQL cluster's server, initdb, pg_ctl, libraries, and share tree (D-041) go
# under SharedSupport: Helpers accepts only nested code and this tree carries SQL and share files.
# The coordinator starts and stops the cluster itself; there is no second LaunchAgent.
mkdir -p "$APP/Contents/SharedSupport"
ditto .build/postgres "$APP/Contents/SharedSupport/postgres"

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
# A bare tool outside a bundle gets an explicit identifier (it defaults to the file name).
# shellcheck disable=SC2086
codesign --force --sign "$IDENTITY" $OPTIONS --identifier "$APP_ID.agent-workspace" \
  "$APP/Contents/Helpers/agent-workspace"
if [ -n "$COORDINATOR_ENTITLEMENTS" ]; then
  # shellcheck disable=SC2086
  codesign --force --sign "$IDENTITY" $OPTIONS --entitlements "$COORDINATOR_ENTITLEMENTS" "$WRAPPER"
else
  # shellcheck disable=SC2086
  codesign --force --sign "$IDENTITY" $OPTIONS "$WRAPPER"
fi
# Re-signing drops what Xcode embedded, so the bundle gets its entitlements again.
# shellcheck disable=SC2086
codesign --force --sign "$IDENTITY" $OPTIONS --entitlements "$APP_ENTITLEMENTS" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"
if [ "$PROFILES" = 1 ]; then
  # The signatures claim exactly the generated entitlements, which the profiles authorise.
  for code in "$APP" "$WRAPPER"; do
    claimed=$(codesign -d --entitlements - --xml "$code" 2>/dev/null)
    for group in $(keychain_groups); do
      case "$claimed" in
        *"<string>$group</string>"*) ;;
        *) echo "$code does not claim the keychain group $group." >&2; exit 1 ;;
      esac
    done
  done
  case "$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)" in
    *"<string>webcredentials:$SITE_DOMAIN</string>"*) ;;
    *) echo "$APP does not claim the associated domain webcredentials:$SITE_DOMAIN." >&2; exit 1 ;;
  esac
  echo "Keychain groups: $(keychain_groups | tr '\n' ' ')(app and coordinator)"
  echo "Associated domain: webcredentials:$SITE_DOMAIN (app)"
fi
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
    # Also checks the embedded profiles against the signatures' entitlements.
    syspolicy_check distribution "$APP"
  fi
fi
du -sh "$APP" "$ZIP"
if [ "$IDENTITY" = "-" ]; then
  echo "Ad hoc signature: this build runs on this Mac. Set B4APP_SIGN_IDENTITY to a Developer ID Application identity for a notarized build (D-039)."
fi
