#!/bin/sh
# Hub/scripts/check-image.sh <image>: asserts the runtime image's contract (D-070).
# libssl3 is on the image only as a dependency of curl; the check is that the hub does not link it.
set -eu
img="$1"
docker run --rm --entrypoint /bin/sh "$img" -c '
  test -s /etc/ssl/certs/rds-global-bundle.pem &&
  test "$(id -u)" = 10001 &&
  test -x /usr/local/bin/b4hub &&
  ! ldd /usr/local/bin/b4hub | grep -q libssl &&
  grep -c "BEGIN CERTIFICATE" /etc/ssl/certs/rds-global-bundle.pem | awk "{exit !(\$1 > 50)}"
'
docker inspect "$img" --format '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' \
  | grep -qx '\["/usr/local/bin/b4hub"\] \["serve"\]'
