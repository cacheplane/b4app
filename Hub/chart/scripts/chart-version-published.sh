#!/usr/bin/env bash
# Asks GHCR whether <ref>:<version> exists. Used for the chart version (hub-chart.yml lint and
# publish) and for the hub image tag the install test pulls.
#
#   chart-version-published.sh ghcr.io/cacheplane/charts/b4hub 0.1.0
#
# Exit codes:
#   0   published (the manifest exists)
#   10  not found: an authenticated 404 with NAME_UNKNOWN (no such repository yet) or
#       MANIFEST_UNKNOWN (no such tag)
#   other  could not tell (network, auth, 5xx, bad arguments); callers must fail, never skip
#
# Credentials come from REGISTRY_USER and REGISTRY_TOKEN (a token with read:packages, such as
# the job's GITHUB_TOKEN with `packages: read`). Anonymous GHCR answers DENIED for both a
# missing and a private repository, so an authenticated request is what makes 404 meaningful.
set -euo pipefail

ref="${1:-}"
version="${2:-}"
if [ -z "$ref" ] || [ -z "$version" ] || [ "$#" -ne 2 ]; then
  echo "usage: $0 <ghcr.io/owner/name> <version>" >&2
  exit 2
fi
: "${REGISTRY_USER:?REGISTRY_USER is required}" "${REGISTRY_TOKEN:?REGISTRY_TOKEN is required}"
case "$ref" in
  ghcr.io/?*) repo="${ref#ghcr.io/}" ;;
  *)
    echo "only ghcr.io references are supported: $ref" >&2
    exit 2
    ;;
esac
# Helm stores a SemVer `+build` suffix as `_build` in OCI tags.
tag="${version//+/_}"
case "$tag" in
  *[!A-Za-z0-9_.-]*)
    echo "invalid tag: $tag" >&2
    exit 2
    ;;
esac

body="$(mktemp)"
trap 'rm -f "$body"' EXIT

code="$(curl -sS -o "$body" -w '%{http_code}' -u "$REGISTRY_USER:$REGISTRY_TOKEN" \
  "https://ghcr.io/token?service=ghcr.io&scope=repository:$repo:pull")" || {
  echo "could not reach the GHCR token endpoint" >&2
  exit 3
}
token="$(jq -r '.token // ""' "$body" 2>/dev/null || true)"
if [ "$code" != 200 ] || [ -z "$token" ]; then
  echo "GHCR token request for $repo returned HTTP $code: $(head -c 300 "$body")" >&2
  exit 3
fi

accept="application/vnd.oci.image.manifest.v1+json,application/vnd.oci.image.index.v1+json"
accept="$accept,application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json"
code="$(curl -sS -o "$body" -w '%{http_code}' -H "Authorization: Bearer $token" -H "Accept: $accept" \
  "https://ghcr.io/v2/$repo/manifests/$tag")" || {
  echo "could not reach ghcr.io for $ref:$tag" >&2
  exit 3
}
case "$code" in
  200)
    echo "$ref:$tag is published"
    exit 0
    ;;
  404)
    errors="$(jq -r '[.errors[]?.code] | join(",")' "$body" 2>/dev/null || true)"
    case ",$errors," in
      *,NAME_UNKNOWN,*)
        echo "$ref does not exist yet (so $tag is not published)"
        exit 10
        ;;
      *,MANIFEST_UNKNOWN,*)
        echo "$ref:$tag is not published"
        exit 10
        ;;
    esac
    ;;
esac
echo "GHCR manifest request for $ref:$tag returned HTTP $code: $(head -c 300 "$body")" >&2
exit 3
