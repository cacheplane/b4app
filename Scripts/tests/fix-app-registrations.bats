#!/usr/bin/env bats
# Scripts/fix-app-registrations.sh against a fixture `lsregister -dump` and a stub lsregister
# (Scripts/tests/stubs/lsregister), which logs the -u and -f calls.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../fix-app-registrations.sh"
  export B4APP_LSREGISTER="$BATS_TEST_DIRNAME/stubs/lsregister"
  export STUB_LOG="$BATS_TEST_TMPDIR/lsregister.log"
  export STUB_DUMP="$BATS_TEST_TMPDIR/dump.txt"
  # Launch Services records real paths (/private/var/…), as the script resolves --dist to.
  DIST="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/checkout/dist"
  mkdir -p "$DIST/Agent Workspace.app" "$DIST/Agent Workspace (Beta).app"
  # The shapes lsregister prints: a bundle record (path before identifier, the record id after the
  # path), a claim record with no identifier, and records of other apps.
  record() { # <path> <identifier> [teamID]
    echo "--------------------------------------------------------------------------------"
    echo "bundle id:                  Agent Workspace (0x5a08)"
    echo "path:                       $1 (0x7898)"
    echo "name:                       Agent Workspace"
    [ $# -ge 3 ] && echo "teamID:                     $3"
    echo "identifier:                 $2"
    echo "version:                    1.0"
    echo ""
  }
  {
    echo "Checking data integrity......done."
    echo "Status: Database is seeded."
    echo ""
    record "/Applications/Safari.app" "com.apple.Safari" "APPLE"
    record "$DIST/Agent Workspace.app" "com.cacheplane.b4app" "GJJKL34HCT"
    record "$DIST/Agent Workspace.app/Contents/Helpers/B4AppCoordinator.app" "com.cacheplane.b4app.coordinator" "GJJKL34HCT"
    record "$DIST/Agent Workspace (Beta).app" "com.cacheplane.b4app.beta" "GJJKL34HCT"
    record "/Users/me/repos/b4app/.build/DerivedData/Build/Products/Release/Agent Workspace.app" "com.cacheplane.b4app"
    record "/Users/me/Library/Developer/Xcode/DerivedData/B4App-abc/Build/Products/Debug/Agent Workspace.app" "com.cacheplane.b4app.local"
    record "/private/tmp/evidence/Agent Workspace (Beta).app" "com.cacheplane.b4app.beta"
    record "/private/tmp/evidence/Agent Workspace (Beta).app/Contents/Helpers/B4AppCoordinator.app" "com.cacheplane.b4app.beta.coordinator"
    record "/Users/me/Library/Developer/Xcode/DerivedData/B4App-abc/Build/Products/Debug-iphonesimulator/Agent Workspace.app" "com.cacheplane.b4app.ios"
    record "/tmp/probe/SMProbe.app" "com.cacheplane.b4app.smprobe"
    echo "--------------------------------------------------------------------------------"
    echo "claim id:                   49160 (0xc008)"
    echo "rank:                       Default"
    echo "bindings:                   '****', 'fold', 'disk'"
    echo ""
  } > "$STUB_DUMP"
}

@test "dry run lists the copies outside dist, marks the missing ones, and changes nothing" {
  run "$SCRIPT" --dist "$DIST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"outside $DIST:"* ]]
  [[ "$output" == *"com.cacheplane.b4app "*"/Release/Agent Workspace.app  (no longer exists)"* ]]
  [[ "$output" == *"com.cacheplane.b4app.local "*"/Debug/Agent Workspace.app"* ]]
  [[ "$output" == *"com.cacheplane.b4app.beta "*"/private/tmp/evidence/Agent Workspace (Beta).app"* ]]
  [[ "$output" == *"com.cacheplane.b4app.beta.coordinator "*"/B4AppCoordinator.app"* ]]
  [[ "$output" != *"$DIST/Agent Workspace.app"* ]]
  [[ "$output" != *"$DIST/Agent Workspace (Beta).app"* ]]
  [[ "$output" != *"b4app.ios"* ]]
  [[ "$output" != *"smprobe"* ]]
  [[ "$output" != *"Safari"* ]]
  [[ "$output" == *"Dry run. Run with --apply"* ]]
  [ ! -e "$STUB_LOG" ]
}

@test "--apply unregisters each copy outside dist and registers the dist apps again" {
  run "$SCRIPT" --dist "$DIST" --apply
  echo "$output"
  [ "$status" -eq 0 ]
  grep -qxF -- "-u /Users/me/repos/b4app/.build/DerivedData/Build/Products/Release/Agent Workspace.app" "$STUB_LOG"
  grep -qxF -- "-u /Users/me/Library/Developer/Xcode/DerivedData/B4App-abc/Build/Products/Debug/Agent Workspace.app" "$STUB_LOG"
  grep -qxF -- "-u /private/tmp/evidence/Agent Workspace (Beta).app" "$STUB_LOG"
  grep -qxF -- "-u /private/tmp/evidence/Agent Workspace (Beta).app/Contents/Helpers/B4AppCoordinator.app" "$STUB_LOG"
  [ "$(grep -c -- '^-u ' "$STUB_LOG")" -eq 4 ]
  ! grep -q -- "-u $DIST" "$STUB_LOG"
  grep -qxF -- "-f $DIST/Agent Workspace.app" "$STUB_LOG"
  grep -qxF -- "-f $DIST/Agent Workspace (Beta).app" "$STUB_LOG"
  [[ "$output" == *"Done. Open the app again"* ]]
}

@test "with nothing outside dist the dry run says so and --apply only re-registers" {
  run "$SCRIPT" --dist "$DIST" --apply
  [ "$status" -eq 0 ]
  run "$SCRIPT" --dist "$DIST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no copy of the app registered outside $DIST"* ]]
  [[ "$output" != *"Dry run"* ]]
}

@test "--apply fails when a copy is still registered afterwards" {
  # A stub that drops nothing: every -u is logged but the dump keeps the record.
  cat > "$BATS_TEST_TMPDIR/stubborn" <<EOF
#!/bin/bash
case "\$1" in -dump) cat "$STUB_DUMP" ;; *) echo "\$1 \$2" >> "$STUB_LOG" ;; esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/stubborn"
  B4APP_LSREGISTER="$BATS_TEST_TMPDIR/stubborn" run "$SCRIPT" --dist "$DIST" --apply
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Still registered outside $DIST:"* ]]
}

@test "unknown arguments and a bare --dist are refused" {
  run "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
  run "$SCRIPT" --dist
  [ "$status" -eq 2 ]
}
