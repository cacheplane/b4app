#!/usr/bin/env bats
# Tests for Hub/chart/scripts/chart-version-published.sh with curl stubbed on
# PATH. The stub is written per test into $BATS_TEST_TMPDIR/bin; it answers the
# token endpoint with STUB_TOKEN_CODE (default 200, a token in the body) and the
# manifest endpoint with STUB_MANIFEST_CODE and STUB_MANIFEST_BODY. Every call
# is appended to $STUB_LOG.

load helpers

setup() {
  root="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  script="$root/Hub/chart/scripts/chart-version-published.sh"
  stubdir="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stubdir"
  export STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
  export REGISTRY_USER=ci
  export REGISTRY_TOKEN=test-token
  : > "$STUB_LOG"
  cat > "$stubdir/curl" << 'STUB'
#!/usr/bin/env bash
out=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -u | -H | -w) shift ;;
    https://*) url="$1" ;;
  esac
  shift
done
printf 'curl %s\n' "$url" >> "${STUB_LOG:?}"
case "$url" in
  https://ghcr.io/token*)
    [ "${STUB_TOKEN_FAIL:-}" = 1 ] && { echo "curl: (6) Could not resolve host" >&2; exit 6; }
    code="${STUB_TOKEN_CODE:-200}"
    if [ "$code" = 200 ]; then body='{"token":"registry-token"}'; else body='{"errors":[{"code":"UNAUTHORIZED"}]}'; fi ;;
  https://ghcr.io/v2/*)
    code="${STUB_MANIFEST_CODE:?}"
    body="${STUB_MANIFEST_BODY:-}" ;;
  *) echo "curl stub: unexpected url $url" >&2; exit 64 ;;
esac
printf '%s' "$body" > "$out"
printf '%s' "$code"
STUB
  chmod +x "$stubdir/curl"
  export PATH="$stubdir:$PATH"
}

@test "200 means published" {
  export STUB_MANIFEST_CODE=200 STUB_MANIFEST_BODY='{}'
  run "$script" ghcr.io/cacheplane/charts/b4hub 0.1.1
  [ "$status" -eq 0 ]
  output_has "is published"
  logged 'curl https://ghcr.io/token?service=ghcr.io&scope=repository:cacheplane/charts/b4hub:pull'
  logged 'curl https://ghcr.io/v2/cacheplane/charts/b4hub/manifests/0.1.1'
}

@test "404 with NAME_UNKNOWN means not published" {
  export STUB_MANIFEST_CODE=404 STUB_MANIFEST_BODY='{"errors":[{"code":"NAME_UNKNOWN","message":"repository name not known to registry"}]}'
  run "$script" ghcr.io/cacheplane/charts/b4hub 0.1.1
  [ "$status" -eq 10 ]
  output_has "does not exist yet"
}

@test "404 with MANIFEST_UNKNOWN means not published" {
  export STUB_MANIFEST_CODE=404 STUB_MANIFEST_BODY='{"errors":[{"code":"MANIFEST_UNKNOWN"}]}'
  run "$script" ghcr.io/cacheplane/charts/b4hub 0.1.1
  [ "$status" -eq 10 ]
}

@test "404 without a known error code is an error, not 'not published'" {
  export STUB_MANIFEST_CODE=404 STUB_MANIFEST_BODY='<html>not found</html>'
  run "$script" ghcr.io/cacheplane/charts/b4hub 0.1.1
  [ "$status" -ne 0 ]
  [ "$status" -ne 10 ]
  output_has "returned HTTP 404"
}

@test "401 on the manifest is an error" {
  export STUB_MANIFEST_CODE=401 STUB_MANIFEST_BODY='{"errors":[{"code":"UNAUTHORIZED"}]}'
  run "$script" ghcr.io/cacheplane/charts/b4hub 0.1.1
  [ "$status" -ne 0 ]
  [ "$status" -ne 10 ]
  output_has "returned HTTP 401"
}

@test "a refused token exchange is an error and skips the manifest request" {
  export STUB_TOKEN_CODE=401 STUB_MANIFEST_CODE=200
  run "$script" ghcr.io/cacheplane/charts/b4hub 0.1.1
  [ "$status" -ne 0 ]
  [ "$status" -ne 10 ]
  output_has "token request for cacheplane/charts/b4hub returned HTTP 401"
  not_logged 'manifests'
}

@test "an unreachable token endpoint is an error" {
  export STUB_TOKEN_FAIL=1 STUB_MANIFEST_CODE=200
  run "$script" ghcr.io/cacheplane/charts/b4hub 0.1.1
  [ "$status" -ne 0 ]
  [ "$status" -ne 10 ]
  output_has "could not reach the GHCR token endpoint"
  not_logged 'manifests'
}

@test "the registry token never appears in the output" {
  export STUB_MANIFEST_CODE=401 STUB_MANIFEST_BODY='{}'
  run "$script" ghcr.io/cacheplane/charts/b4hub 0.1.1
  output_lacks "test-token"
  output_lacks "registry-token"
}
