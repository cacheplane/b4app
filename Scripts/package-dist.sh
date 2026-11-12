# shellcheck shell=sh
# Sourced by Scripts/package.sh (POSIX sh). The three flavours' apps sit side by side in dist/, so
# packaging one replaces only that flavour's outputs: emptying dist/ took the other flavours' apps,
# and with them the bundles their running coordinators and LaunchAgents pointed at.

# clear_flavour_outputs <dist> <name suffix> <zip suffix>: remove the flavour's app
# ("Agent Workspace<name suffix>.app"), its zips of any version ("Agent-Workspace<zip suffix>-<version>.zip"),
# and its notarization results ("notarize<zip suffix>-<version>.json"); create <dist> if missing.
# A version starts with a digit, so prod's patterns ("Agent-Workspace-[0-9]*") never match Beta's or
# Local's ("Agent-Workspace-Beta-…").
clear_flavour_outputs() {
  mkdir -p "$1"
  rm -rf "$1/Agent Workspace$2.app"
  for output in "$1/Agent-Workspace$3-"[0-9]*.zip "$1/notarize$3-"[0-9]*.json; do
    if [ -e "$output" ]; then rm -f "$output"; fi
  done
}
