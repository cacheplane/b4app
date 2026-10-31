#!/bin/sh
# Fetch the pinned PostgreSQL server for the app (decision D-041) into .build/postgres: server,
# initdb, pg_ctl, their libraries, and the share tree. The archive is checked against a pinned
# SHA-256 before anything is extracted; the tree is thinned to arm64 and duplicate library copies
# become symlinks. Package.sh copies the result into Contents/Helpers/postgres.
#
#   ./Scripts/fetch-postgres.sh          # no-op when .build/postgres already holds this version
#   ./Scripts/fetch-postgres.sh --force
set -eu
cd "$(dirname "$0")/.."

PG_VERSION="17.11.0"
PG_SHA256="a1c2786acb0c398f9b2d76806fc52f5dc8b222cbc8e9383a9b9702084daaf3a5"
ARTIFACT="embedded-postgres-binaries-darwin-arm64v8"
JAR="$ARTIFACT-$PG_VERSION.jar"
URL="https://repo1.maven.org/maven2/io/zonky/test/postgres/$ARTIFACT/$PG_VERSION/$JAR"
DEST=.build/postgres
DL=.build/postgres-dl

if [ "${1:-}" != "--force" ] && [ -f "$DEST/VERSION" ] && [ "$(cat "$DEST/VERSION")" = "$PG_VERSION" ]; then
  echo "postgres $PG_VERSION already in $DEST"
  exit 0
fi
case "$(uname -m)" in
  arm64) ;;
  *) echo "fetch-postgres.sh pins the arm64 build; this Mac is $(uname -m)" >&2; exit 1 ;;
esac

mkdir -p "$DL"
if [ ! -f "$DL/$JAR" ]; then
  echo "==> Downloading $URL"
  curl -fsSL -o "$DL/$JAR.part" "$URL"
  mv "$DL/$JAR.part" "$DL/$JAR"
fi
ACTUAL=$(shasum -a 256 "$DL/$JAR" | cut -d' ' -f1)
if [ "$ACTUAL" != "$PG_SHA256" ]; then
  echo "checksum mismatch for $JAR: expected $PG_SHA256, got $ACTUAL" >&2
  rm -f "$DL/$JAR"
  exit 1
fi

echo "==> Extracting"
rm -rf "$DEST"
mkdir -p "$DEST"
unzip -q -o "$DL/$JAR" postgres-darwin-arm_64.txz -d "$DEST"
tar -xJf "$DEST/postgres-darwin-arm_64.txz" -C "$DEST"
rm "$DEST/postgres-darwin-arm_64.txz"

echo "==> Thinning to arm64 and pruning"
# Universal binaries: keep arm64 only.
find "$DEST/bin" "$DEST/lib" -type f \( -perm -u+x -o -name "*.dylib" \) | while read -r f; do
  if file "$f" | grep -q "universal binary"; then
    lipo -thin arm64 "$f" -output "$f.arm64" && mv "$f.arm64" "$f"
  fi
done
# Each library ships as three identical copies (libfoo.dylib, libfoo.N.dylib, libfoo.N.M.dylib):
# keep the most specific real file and link the others to it.
cd "$DEST/lib"
for f in *.dylib; do
  [ -L "$f" ] && continue
  base=$(echo "$f" | sed -E 's/\.[0-9.]+\.dylib$/.dylib/; s/\.dylib$//')
  longest=$(ls "$base".*.dylib "$base.dylib" 2>/dev/null | awk '{ print length, $0 }' | sort -rn | head -1 | cut -d' ' -f2-)
  [ -n "$longest" ] || continue
  for other in "$base".*.dylib "$base.dylib"; do
    [ -e "$other" ] || continue
    if [ "$other" != "$longest" ] && [ ! -L "$other" ] && cmp -s "$other" "$longest"; then
      ln -sf "$longest" "$other"
    fi
  done
done
# Server-side modules: PL/pgSQL (the change-log triggers) and dict_snowball (initdb needs it).
find postgresql -maxdepth 1 -type f ! -name "plpgsql.dylib" ! -name "dict_snowball.dylib" -delete
cd "$OLDPWD"
find "$DEST/share/postgresql/extension" -type f ! -name "plpgsql*" -delete
echo "$PG_VERSION" > "$DEST/VERSION"

"$DEST/bin/postgres" --version
du -sh "$DEST" | cut -f1 | sed 's/^/size: /'
