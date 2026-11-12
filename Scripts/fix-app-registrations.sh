#!/bin/bash
# Unregister every copy of the Mac app that Launch Services knows besides the packaged ones in dist/,
# and register those again (D-173).
#
# macOS keeps one Launch Services record per copy of an app it has seen: every Xcode build product
# (Xcode registers each one it builds), every scratch copy, every other checkout's dist/. The daemon
# that checks associated domains (swcd) looks the bundle id up and can pick any of those copies, and
# the Xcode intermediates and ad hoc copies carry no webcredentials entitlement. Then "Continue with
# Apple" (an https callback) and passkeys fail with no page shown, and the log says the app "is not
# associated with domain b4.run" although the packaged app is.
#
#   ./Scripts/fix-app-registrations.sh            list the copies registered outside dist/ (dry run)
#   ./Scripts/fix-app-registrations.sh --apply    unregister them (paths that no longer exist too),
#                                                 then register the apps in dist/ again; reopen the app
#   --dist DIR                                    the dist/ to keep (default: this checkout's)
#   --keep PATH                                   also keep this app, or the apps in this directory,
#                                                 and register it again (repeatable; e.g. the Local
#                                                 app in /Applications beside the main dist/)
#
# Never touches the apps in dist/ or a kept path except to register them again, and never unregisters a
# copy that is running (quit it first). Covers the three flavours' bundle ids and their coordinators.
set -euo pipefail

LSREGISTER="${B4APP_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
PLUTIL="${B4APP_PLUTIL:-/usr/bin/plutil}"
# The app ids of the three flavours (Flavor.swift) and their coordinator bundles.
ID_PATTERN='^com\.cacheplane\.b4app(\.beta|\.local)?(\.coordinator)?$'

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
}

APPLY=0
DIST=""
# The kept paths, one per line (bash 3.2 has no safe empty array under `set -u`).
KEEP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --dist)
      [ $# -ge 2 ] || { echo "--dist needs a directory." >&2; exit 2; }
      DIST="$2"
      shift
      ;;
    --keep)
      [ $# -ge 2 ] || { echo "--keep needs a path." >&2; exit 2; }
      # Launch Services records real paths, so resolve the kept one the same way.
      if [ -e "$2" ]; then kept="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"; else kept="$2"; fi
      KEEP="$KEEP$kept"$'\n'
      shift
      ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown argument '$1'." >&2; usage >&2; exit 2 ;;
  esac
  shift
done
if [ -z "$DIST" ]; then
  DIST="$(cd "$(dirname "$0")/.." && pwd -P)/dist"
elif [ -d "$DIST" ]; then
  DIST="$(cd "$DIST" && pwd -P)"
fi
if [ ! -x "$LSREGISTER" ]; then
  echo "lsregister is not at $LSREGISTER; this script is for macOS." >&2
  exit 1
fi

# registrations: "<bundle id><TAB><path>" for every Launch Services record of one of our bundle ids.
# In `lsregister -dump` records are separated by a line of dashes, and a bundle record's `path:` line
# precedes its `identifier:` line; the path ends in the record's id, "(0x1234)", which is dropped.
registrations() {
  "$LSREGISTER" -dump | awk -v ids="$ID_PATTERN" '
    /^----------/ { path = ""; next }
    /^path:/ {
      path = $0
      sub(/^path:[ \t]*/, "", path)
      sub(/ \(0x[0-9a-f]+\)$/, "", path)
      next
    }
    /^identifier:/ {
      id = $0
      sub(/^identifier:[ \t]*/, "", id)
      if (id ~ ids && path != "") print id "\t" path
    }
  ' | sort -u
}

# in_dist <path>: the path is the dist/ directory or a kept path, or inside one of them.
in_dist() {
  case "$1" in
    "$DIST" | "$DIST"/*) return 0 ;;
  esac
  while IFS= read -r kept; do
    [ -n "$kept" ] || continue
    case "$1" in
      "$kept" | "$kept"/*) return 0 ;;
    esac
  done <<< "$KEEP"
  return 1
}

# running <path>: some process runs an executable inside the bundle. `ps -o comm` prints the
# executable's path; pgrep would take the path as a pattern (parentheses, dots). grep reads all of it:
# with -q it stops at the first match, ps dies of SIGPIPE, and pipefail made a running copy look idle.
running() {
  # shellcheck disable=SC2009
  ps -axo comm= | grep -F -- "$1/" >/dev/null
}

# strays: the registrations outside dist/, "<bundle id><TAB><path>".
strays() {
  registrations | while IFS=$'\t' read -r id path; do
    in_dist "$path" || printf '%s\t%s\n' "$id" "$path"
  done
}

# ours <app>: the bundle is one of the three flavours' apps (by its Info.plist), so a kept directory
# such as /Applications only has our apps registered again, not every app in it.
ours() {
  id=$("$PLUTIL" -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null) || return 1
  [[ "$id" =~ $ID_PATTERN ]]
}

describe() { # <bundle id> <path>
  note=""
  if [ ! -e "$2" ]; then note="  (no longer exists)"; fi
  if running "$2"; then note="  (running: left alone; quit it, then run again)"; fi
  printf '  %-40s %s%s\n' "$1" "$2" "$note"
}

FOUND=$(strays)
if [ -z "$FOUND" ]; then
  echo "Launch Services has no copy of the app registered outside $DIST."
else
  echo "Registered with Launch Services outside $DIST:"
  while IFS=$'\t' read -r id path; do describe "$id" "$path"; done <<< "$FOUND"
fi

if [ "$APPLY" != 1 ]; then
  if [ -n "$FOUND" ]; then
    echo "Dry run. Run with --apply to unregister these and register the apps in $DIST (and any --keep) again."
  fi
  exit 0
fi

if [ -n "$FOUND" ]; then
  echo "==> Unregistering"
  while IFS=$'\t' read -r id path; do
    if running "$path"; then continue; fi
    # A path that no longer exists makes lsregister complain that it cannot scan it, but the record
    # goes all the same; the check below is what counts.
    "$LSREGISTER" -u "$path" >/dev/null 2>&1 || true
    echo "  $path"
  done <<< "$FOUND"
fi

echo "==> Registering the apps in $DIST"
registered=0
for app in "$DIST"/*.app; do
  if [ ! -d "$app" ] || ! ours "$app"; then continue; fi
  "$LSREGISTER" -f "$app"
  echo "  $app"
  registered=$((registered + 1))
done
if [ "$registered" = 0 ]; then
  echo "  (none: $DIST has no app of ours)"
fi
while IFS= read -r kept; do
  [ -n "$kept" ] || continue
  if [ -d "$kept" ] && [ "${kept%.app}" = "$kept" ]; then
    apps=("$kept"/*.app)
  else
    apps=("$kept")
  fi
  for app in "${apps[@]}"; do
    if [ ! -d "$app" ] || ! ours "$app"; then continue; fi
    "$LSREGISTER" -f "$app"
    echo "  $app (kept)"
  done
done <<< "$KEEP"

LEFT=$(strays)
if [ -n "$LEFT" ]; then
  echo "Still registered outside $DIST:"
  while IFS=$'\t' read -r id path; do describe "$id" "$path"; done <<< "$LEFT"
  if grep -qvF "(running" < <(while IFS=$'\t' read -r id path; do describe "$id" "$path"; done <<< "$LEFT"); then
    echo "Some copies could not be unregistered." >&2
    exit 1
  fi
  echo "Only running copies are left; quit them and run again."
  exit 1
fi
echo "Done. Open the app again so the association is checked afresh."
