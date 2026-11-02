#!/usr/bin/env bash
# Prints the image tags a hub release tag publishes, one per line.
#   hub-v1.2.3      -> 1.2.3, 1.2, 1, latest
#   hub-v1.0.0-rc1  -> 1.0.0-rc1 only (a prerelease never moves X.Y, X, or latest)
set -euo pipefail

tag="${1:-}"
version="${tag#hub-v}"
semver='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$'

if [ "$version" = "$tag" ] || ! [[ "$version" =~ $semver ]]; then
  echo "not a hub release tag with a semver version: $tag" >&2
  exit 1
fi

echo "$version"
if [ -z "${BASH_REMATCH[4]}" ]; then
  echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
  echo "${BASH_REMATCH[1]}"
  echo latest
fi
