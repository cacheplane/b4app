#!/usr/bin/env bats
# Scripts/package-dist.sh: packaging one flavour replaces only that flavour's outputs in dist/, so
# the prod, Beta, and Local apps can sit side by side there (2026-11-10 a Local build emptied dist/
# and took the prod and Beta apps whose coordinators were running).

setup() {
  # shellcheck source=Scripts/package-dist.sh
  . "$BATS_TEST_DIRNAME/../package-dist.sh"
  DIST="$BATS_TEST_TMPDIR/dist"
  mkdir -p "$DIST/Agent Workspace.app/Contents" "$DIST/Agent Workspace (Beta).app/Contents" \
    "$DIST/Agent Workspace (Local).app/Contents" "$DIST/ios"
  touch "$DIST/Agent-Workspace-0.1.0.zip" "$DIST/Agent-Workspace-0.0.9.zip" \
    "$DIST/Agent-Workspace-Beta-0.1.0.zip" "$DIST/Agent-Workspace-Local-0.1.0.zip" \
    "$DIST/notarize-0.1.0.json" "$DIST/notarize-Beta-0.1.0.json" "$DIST/ios/B4App.ipa"
}

left() { (cd "$DIST" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||' | LC_ALL=C sort | tr '\n' '|'); }

@test "packaging prod clears only prod's app, zips, and notarization results" {
  clear_flavour_outputs "$DIST" "" ""
  [ "$(left)" = "Agent Workspace (Beta).app|Agent Workspace (Local).app|Agent-Workspace-Beta-0.1.0.zip|Agent-Workspace-Local-0.1.0.zip|ios|notarize-Beta-0.1.0.json|" ]
}

@test "packaging Local leaves the prod and Beta apps alone" {
  clear_flavour_outputs "$DIST" " (Local)" "-Local"
  [ -d "$DIST/Agent Workspace.app" ]
  [ -d "$DIST/Agent Workspace (Beta).app" ]
  [ ! -e "$DIST/Agent Workspace (Local).app" ]
  [ ! -e "$DIST/Agent-Workspace-Local-0.1.0.zip" ]
  [ -e "$DIST/Agent-Workspace-0.1.0.zip" ]
  [ -e "$DIST/notarize-0.1.0.json" ]
  [ -e "$DIST/ios/B4App.ipa" ]
}

@test "a missing dist/ is created" {
  clear_flavour_outputs "$BATS_TEST_TMPDIR/fresh" " (Beta)" "-Beta"
  [ -d "$BATS_TEST_TMPDIR/fresh" ]
}
