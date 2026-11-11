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
  # app <path> <bundle id>: a bundle directory with the Info.plist the script reads its id from.
  app() {
    mkdir -p "$1/Contents"
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string></dict></plist>\n' "$2" > "$1/Contents/Info.plist"
  }
  app "$DIST/Agent Workspace.app" com.cacheplane.b4app
  app "$DIST/Agent Workspace (Beta).app" com.cacheplane.b4app.beta
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
  [[ "$output" == *"outside $DIST:"* ]] || false
  [[ "$output" == *"com.cacheplane.b4app "*"/Release/Agent Workspace.app  (no longer exists)"* ]] || false
  [[ "$output" == *"com.cacheplane.b4app.local "*"/Debug/Agent Workspace.app"* ]] || false
  [[ "$output" == *"com.cacheplane.b4app.beta "*"/private/tmp/evidence/Agent Workspace (Beta).app"* ]] || false
  [[ "$output" == *"com.cacheplane.b4app.beta.coordinator "*"/B4AppCoordinator.app"* ]] || false
  [[ "$output" != *"$DIST/Agent Workspace.app"* ]] || false
  [[ "$output" != *"$DIST/Agent Workspace (Beta).app"* ]] || false
  [[ "$output" != *"b4app.ios"* ]] || false
  [[ "$output" != *"smprobe"* ]] || false
  [[ "$output" != *"Safari"* ]] || false
  [[ "$output" == *"Dry run. Run with --apply"* ]] || false
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
  ! grep -q -- "-u $DIST" "$STUB_LOG" || false
  grep -qxF -- "-f $DIST/Agent Workspace.app" "$STUB_LOG"
  grep -qxF -- "-f $DIST/Agent Workspace (Beta).app" "$STUB_LOG"
  [[ "$output" == *"Done. Open the app again"* ]] || false
}

@test "with nothing outside dist the dry run says so and --apply only re-registers" {
  run "$SCRIPT" --dist "$DIST" --apply
  [ "$status" -eq 0 ]
  run "$SCRIPT" --dist "$DIST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no copy of the app registered outside $DIST"* ]] || false
  [[ "$output" != *"Dry run"* ]] || false
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
  [[ "$output" == *"Still registered outside $DIST:"* ]] || false
}

@test "unknown arguments and a bare --dist or --keep are refused" {
  run "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
  run "$SCRIPT" --dist
  [ "$status" -eq 2 ]
  run "$SCRIPT" --keep
  [ "$status" -eq 2 ]
}

@test "a running copy is marked and left alone, however much ps prints after it" {
  # ps lists the running copy first and then many more processes. With `grep -q` under pipefail,
  # grep's early exit killed ps with SIGPIPE and the copy read as not running (exit 141).
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/ps" <<'EOF'
#!/bin/bash
echo "/private/tmp/evidence/Agent Workspace (Beta).app/Contents/MacOS/Agent Workspace"
for i in $(seq 1 20000); do echo "/usr/libexec/process-$i"; done
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/ps"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$SCRIPT" --dist "$DIST" --apply
  echo "$output"
  [[ "$output" == *"/private/tmp/evidence/Agent Workspace (Beta).app  (running: left alone"* ]] || false
  ! grep -qxF -- "-u /private/tmp/evidence/Agent Workspace (Beta).app" "$STUB_LOG" || false
  grep -qxF -- "-u /Users/me/repos/b4app/.build/DerivedData/Build/Products/Release/Agent Workspace.app" "$STUB_LOG"
}

@test "--keep keeps another copy, and --apply registers it again with the dist apps" {
  # The Local app installed outside dist/, as /Applications holds it.
  LOCAL="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/Applications/Agent Workspace (Local).app"
  app "$LOCAL" com.cacheplane.b4app.local
  record "$LOCAL" "com.cacheplane.b4app.local" "GJJKL34HCT" >> "$STUB_DUMP"
  record "$LOCAL/Contents/Helpers/B4AppCoordinator.app" "com.cacheplane.b4app.local.coordinator" >> "$STUB_DUMP"
  run "$SCRIPT" --dist "$DIST" --keep "$LOCAL"
  echo "$output"
  [[ "$output" != *"Applications/Agent Workspace (Local).app"* ]] || false
  run "$SCRIPT" --dist "$DIST" --keep "$LOCAL" --apply
  echo "$output"
  [ "$status" -eq 0 ]
  ! grep -q -- "-u $LOCAL" "$STUB_LOG" || false
  grep -qxF -- "-f $LOCAL" "$STUB_LOG"
  grep -qxF -- "-f $DIST/Agent Workspace.app" "$STUB_LOG"
  [ "$(grep -c -- '^-u ' "$STUB_LOG")" -eq 4 ]
}

@test "only the three flavours' apps are registered again, not other apps in a kept directory" {
  # --dist /Applications, or a kept directory that holds other apps besides ours.
  APPS="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/Applications"
  app "$APPS/Agent Workspace (Local).app" com.cacheplane.b4app.local
  app "$APPS/Safari.app" com.apple.Safari
  mkdir -p "$APPS/No Info.app"
  record "$APPS/Agent Workspace (Local).app" "com.cacheplane.b4app.local" "GJJKL34HCT" >> "$STUB_DUMP"
  run "$SCRIPT" --dist "$DIST" --keep "$APPS" --apply
  echo "$output"
  [ "$status" -eq 0 ]
  grep -qxF -- "-f $APPS/Agent Workspace (Local).app" "$STUB_LOG"
  grep -qxF -- "-f $DIST/Agent Workspace.app" "$STUB_LOG"
  ! grep -qF -- "Safari.app" "$STUB_LOG" || false
  ! grep -qF -- "No Info.app" "$STUB_LOG" || false
}
