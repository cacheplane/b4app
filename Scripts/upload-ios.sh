#!/bin/sh
# Archive the iOS companion and upload it to App Store Connect for TestFlight (D-051).
#
#   B4APP_ASC_KEY_ID=… B4APP_ASC_ISSUER_ID=… ./Scripts/upload-ios.sh
#   B4APP_UPLOAD=0 …                 export and validate the .ipa under dist/ios, upload nothing
#   B4APP_FLAVOR=beta …              the beta flavour (the test hub); prod is the default. The local
#                                    flavour is a Simulator and Xcode build, never uploaded. Both
#                                    uploadable flavours share the App ID com.cacheplane.b4app.ios and
#                                    differ in the hub, the site domain, and the URL scheme.
#   B4APP_TESTFLIGHT_EXTERNAL=1 …    allow the build to go to external testers (Beta App Review)
#
# Signing is automatic and cloud-managed: the export registers the App ID, creates the App Store
# profile, and signs with an Apple Distribution certificate Apple manages, authorised by a Team App
# Store Connect API key with the Admin role. altool then validates and uploads the .ipa with the same
# key (Xcode 26.6's own `destination: upload` failed here with "Cannot verify client's JWT headers"
# while altool, with the same key, succeeded; D-051). The key file stays outside the repository, by default at
# ~/.appstoreconnect/private_keys/AuthKey_<key id>.p8 (B4APP_ASC_KEY_PATH overrides it); this script
# never prints it. The team id comes from B4APP_TEAM_ID or the Developer ID identity in the login
# keychain. The build number is B4APP_BUILD_NUMBER or the UTC time as yymmddHHMM, so each upload is
# newer than the last; the marketing version comes from Sources/Coordinator/Version.swift.
set -eu
cd "$(dirname "$0")/.."

FLAVOR="${B4APP_FLAVOR:-prod}"
case "$FLAVOR" in
  prod) XCODE_CONFIG=Release; SITE_DOMAIN=b4.run; URL_SCHEME=b4app; OUT=dist/ios ;;
  beta) XCODE_CONFIG=Release-Beta; SITE_DOMAIN=test.b4.run; URL_SCHEME=b4app-beta; OUT=dist/ios-beta ;;
  local)
    echo "The local flavour has a different App ID and talks to localhost; run it from Xcode or the Simulator, not TestFlight." >&2
    exit 1
    ;;
  *)
    echo "B4APP_FLAVOR must be prod or beta, not '$FLAVOR'." >&2
    exit 1
    ;;
esac
BUNDLE_ID=com.cacheplane.b4app.ios
VERSION=$(sed -n 's/.*public static let current = "\(.*\)".*/\1/p' Sources/Coordinator/Version.swift)
BUILD="${B4APP_BUILD_NUMBER:-$(date -u +%y%m%d%H%M)}"
KEY_ID="${B4APP_ASC_KEY_ID:-}"
ISSUER_ID="${B4APP_ASC_ISSUER_ID:-}"
if [ -z "$KEY_ID" ] || [ -z "$ISSUER_ID" ]; then
  echo "Set B4APP_ASC_KEY_ID and B4APP_ASC_ISSUER_ID (App Store Connect → Users and Access → Integrations)." >&2
  exit 1
fi
KEY_PATH="${B4APP_ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8}"
if [ ! -f "$KEY_PATH" ]; then
  echo "No App Store Connect API key at $KEY_PATH (set B4APP_ASC_KEY_PATH)." >&2
  exit 1
fi
TEAM_ID="${B4APP_TEAM_ID:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"Developer ID Application: .*(\([A-Z0-9]\{10\}\))"$/\1/p' | head -1)}"
if [ -z "$TEAM_ID" ]; then
  echo "Set B4APP_TEAM_ID; no Developer ID identity in the keychain to read it from." >&2
  exit 1
fi
ARCHIVE="$OUT/B4App-iOS.xcarchive"
AUTH="-allowProvisioningUpdates -authenticationKeyPath $KEY_PATH -authenticationKeyID $KEY_ID -authenticationKeyIssuerID $ISSUER_ID"
case "$KEY_PATH" in
  *" "*) echo "B4APP_ASC_KEY_PATH must not contain spaces." >&2; exit 1 ;;
esac

echo "==> Generating the Xcode project"
./Scripts/generate-project.sh >/dev/null

echo "==> Archiving B4App-iOS $VERSION ($BUILD), $FLAVOR flavour, for team $TEAM_ID"
rm -rf "$OUT"
mkdir -p "$OUT"
# The archive is left unsigned: an automatically signed archive needs a development profile, which
# needs a registered device, and the export below signs everything for distribution anyway.
xcodebuild archive -project B4App.xcodeproj -scheme B4App-iOS -configuration "$XCODE_CONFIG" \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" -derivedDataPath .build/DerivedData-ios \
  DEVELOPMENT_TEAM="$TEAM_ID" MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGNING_ALLOWED=NO -quiet

# The archived app must not carry the Debug-only localhost exception, and must carry its manifest.
INFO="$ARCHIVE/Products/Applications/Agent Workspace.app/Info.plist"
if plutil -extract NSAppTransportSecurity raw -o - "$INFO" >/dev/null 2>&1; then
  echo "The archive still has NSAppTransportSecurity; the Release post-build script did not run." >&2
  exit 1
fi
# ...and must be the flavour asked for, since the hub and the passkey domain follow from it.
for expected in "B4AppFlavor:$FLAVOR" "CFBundleIdentifier:$BUNDLE_ID" "CFBundleURLTypes:0:CFBundleURLSchemes:0:$URL_SCHEME"; do
  key=${expected%:*}
  want=${expected##*:}
  got=$(/usr/libexec/PlistBuddy -c "Print :$key" "$INFO" 2>/dev/null || true)
  if [ "$got" != "$want" ]; then
    echo "The archive's Info.plist has $key '$got', not '$want' ($FLAVOR flavour, site $SITE_DOMAIN)." >&2
    exit 1
  fi
done
[ -f "$ARCHIVE/Products/Applications/Agent Workspace.app/PrivacyInfo.xcprivacy" ] || {
  echo "The archive has no PrivacyInfo.xcprivacy." >&2
  exit 1
}

if [ "${B4APP_TESTFLIGHT_EXTERNAL:-0}" = 1 ]; then INTERNAL=false; else INTERNAL=true; fi
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>testFlightInternalTestingOnly</key><$INTERNAL/>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
EOF
plutil -lint "$OUT/ExportOptions.plist" >/dev/null

echo "==> Exporting and signing for App Store Connect"
# shellcheck disable=SC2086
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT/export" $AUTH
IPA="$OUT/export/Agent Workspace.ipa"
ALTOOL_AUTH="--apiKey $KEY_ID --apiIssuer $ISSUER_ID"
if [ -n "${B4APP_ASC_KEY_PATH:-}" ]; then
  # altool looks for AuthKey_<id>.p8 in ~/.appstoreconnect/private_keys and a few other folders.
  export API_PRIVATE_KEYS_DIR
  API_PRIVATE_KEYS_DIR=$(dirname "$KEY_PATH")
fi

echo "==> Validating with App Store Connect"
# shellcheck disable=SC2086
xcrun altool --validate-app -f "$IPA" -t ios $ALTOOL_AUTH
if [ "${B4APP_UPLOAD:-1}" = 0 ]; then
  echo "B4APP_UPLOAD=0: validated $IPA ($VERSION, $BUILD), not uploaded."
  exit 0
fi
echo "==> Uploading"
# shellcheck disable=SC2086
xcrun altool --upload-app -f "$IPA" -t ios $ALTOOL_AUTH
echo "Uploaded $VERSION ($BUILD). App Store Connect emails when processing finishes; then add it to a TestFlight group."
