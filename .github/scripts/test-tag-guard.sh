#!/usr/bin/env bash
# Asserts which release tags the hub release workflow runs for. Mac app
# releases (mac-v*) fire the same `release: published` event and must skip.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=0

check() {
  local tag="$1" want="$2" got
  if "$here/is-hub-release.sh" "$tag" 2>/dev/null; then got=run; else got=skip; fi
  if [ "$got" = "$want" ]; then
    echo "ok   $tag -> $want"
  else
    echo "FAIL $tag -> $got (want $want)" >&2
    failed=1
  fi
}

check hub-v0.1.0 run
check hub-v10.2.3-rc1 run
check mac-v1.0.0 skip
check v1.0.0 skip
check hubv1 skip

check_tags() {
  local tag="$1" want="$2" got
  got="$("$here/hub-release-tags.sh" "$tag" 2>/dev/null | paste -sd, -)" || got=error
  if [ "$got" = "$want" ]; then
    echo "ok   tags $tag -> $want"
  else
    echo "FAIL tags $tag -> $got (want $want)" >&2
    failed=1
  fi
}

check_tags hub-v0.1.0 0.1.0,0.1,0,latest
check_tags hub-v10.2.3 10.2.3,10.2,10,latest
check_tags hub-v1.0.0-rc1 1.0.0-rc1
check_tags hub-v1.0 error
check_tags mac-v1.0.0 error

exit "$failed"
