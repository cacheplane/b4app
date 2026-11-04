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
#
# Never touches the apps in dist/ except to register them again, and never unregisters a copy that is
# running (quit it first). Covers the three flavours' bundle ids and their coordinator bundles.
set -euo pipefail

LSREGISTER="${B4APP_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
# The app ids of the three flavours (Flavor.swift) and their coordinator bundles.
ID_PATTERN='^com\.cacheplane\.b4app(\.beta|\.local)?(\.coordinator)?$'

usage() {
  sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
}

APPLY=0
DIST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --dist)
      [ $# -ge 2 ] || { echo "--dist needs a directory." >&2; exit 2; }
      DIST="$2"
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

# in_dist <path>: the path is the dist/ directory or inside it.
in_dist() {
  case "$1" in
    "$DIST" | "$DIST"/*) return 0 ;;
  esac
  return 1
}

# running <path>: some process runs an executable inside the bundle. `ps -o comm` prints the
# executable's path; pgrep would take the path as a pattern (parentheses, dots).
running() {
  # shellcheck disable=SC2009
  ps -axo comm= | grep -qF -- "$1/"
}

# strays: the registrations outside dist/, "<bundle id><TAB><path>".
strays() {
  registrations | while IFS=$'\t' read -r id path; do
    in_dist "$path" || printf '%s\t%s\n' "$id" "$path"
  done
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
    echo "Dry run. Run with --apply to unregister these and register the apps in $DIST again."
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
  [ -d "$app" ] || continue
  "$LSREGISTER" -f "$app"
  echo "  $app"
  registered=$((registered + 1))
done
if [ "$registered" = 0 ]; then
  echo "  (none: $DIST has no .app)"
fi

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
