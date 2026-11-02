# Assertions that fail under bats' errexit on every bash version: `! cmd` and
# a false `[[ ... ]]` (bash < 4.1) do not stop a test, a failing function does.
# shellcheck shell=bash disable=SC2154 # $output is set by bats' run

logged() { # pattern: a stub call matching it was recorded
  grep -q -- "$1" "$STUB_LOG" || { echo "expected a call matching: $1" >&2; return 1; }
}

not_logged() { # pattern: no stub call matches it
  if grep -q -- "$1" "$STUB_LOG"; then
    echo "unexpected call matching: $1" >&2
    grep -- "$1" "$STUB_LOG" >&2
    return 1
  fi
}

output_has() { # text
  case "$output" in
    *"$1"*) ;;
    *) echo "output lacks: $1" >&2; return 1 ;;
  esac
}

output_lacks() { # text
  case "$output" in
    *"$1"*) echo "output contains: $1" >&2; return 1 ;;
  esac
}
