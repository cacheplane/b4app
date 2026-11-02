#!/bin/bash
# Release the Mac app: package, notarize, publish to GitHub Releases, and for prod open a pull
# request on the Homebrew tap (sign-in plan, D-062). Owner-run: the Developer ID identity and the
# notary profile live on the owner's Mac (D-039).
#
#   B4APP_SIGN_IDENTITY="Developer ID Application: …" ./Scripts/release-mac.sh 0.2.0
#   B4APP_FLAVOR=beta B4APP_SIGN_IDENTITY=… ./Scripts/release-mac.sh 0.2.0
#   ./Scripts/release-mac.sh 0.2.0 --dry-run          print every step; run none of the outward ones
#
# B4APP_FLAVOR is prod (the default) or beta; local is never released. <version> must be X.Y.Z and
# equal MARKETING_VERSION in project.yml and the version in Sources/Coordinator/Version.swift, which
# is what package.sh names the zip with.
#
# A real run, in order:
#   1. Scripts/package.sh, which signs with B4APP_SIGN_IDENTITY, notarizes, staples, and zips.
#   2. The zip's SHA-256.
#   3. gh release create mac-v<version> (mac-v<version>-beta --prerelease for beta) on
#      cacheplane/b4app, with the versioned zip. Prod also attaches the same file as
#      Agent-Workspace.zip, so releases/latest/download/Agent-Workspace.zip works (the b4.run
#      download page links that name).
#   4. Prod only: in the tap cloned during the preflight, set version and sha256 in Casks/agent-workspace.rb
#      (starting from Packaging/homebrew/agent-workspace.rb when the tap has no cask yet), push a
#      branch, and open a pull request. The owner merges it.
#
# Before step 1 a real run checks everything that could fail later: a clean tree, HEAD on the remote
# (fetched), the signing and notary settings, gh signed in, no such release yet, and for prod that
# the tap exists, you can push to it, and its branch agent-workspace-<version> is free (it clones the
# tap and cuts the branch then, so nothing goes public unless the cask pull request can follow).
#
# A dry run builds nothing, signs nothing, and never runs gh or git push. It hashes the zip already
# under dist/ if there is one and otherwise prints a placeholder. It tolerates a dirty tree.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE_REPO=cacheplane/b4app
TAP_REPO=cacheplane/homebrew-tap
CASK_TEMPLATE=Packaging/homebrew/agent-workspace.rb
CASK_PATH=Casks/agent-workspace.rb
DIST=dist

usage() {
  echo "usage: [B4APP_FLAVOR=prod|beta] $0 <version> [--dry-run]" >&2
  exit 2
}

fail() {
  echo "$1" >&2
  exit 1
}

VERSION=""
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -*) usage ;;
    *) if [ -n "$VERSION" ]; then usage; fi; VERSION="$arg" ;;
  esac
done
if [ -z "$VERSION" ]; then usage; fi

# The flavour: names mirror package.sh. Prod gets the stable asset and the tap; beta is a prerelease.
FLAVOR="${B4APP_FLAVOR:-prod}"
case "$FLAVOR" in
  prod)
    TAG="mac-v$VERSION"; ZIP_SUFFIX=""; TITLE="Agent Workspace $VERSION"
    ;;
  beta)
    TAG="mac-v$VERSION-beta"; ZIP_SUFFIX="-Beta"; TITLE="Agent Workspace $VERSION (Beta)"
    ;;
  local)
    fail "The local flavour is never released; B4APP_FLAVOR must be prod or beta."
    ;;
  *)
    fail "B4APP_FLAVOR must be prod or beta, not '$FLAVOR'."
    ;;
esac
ZIP="$DIST/Agent-Workspace$ZIP_SUFFIX-$VERSION.zip"
STABLE_ZIP_NAME=Agent-Workspace.zip

# --- Checks that need no network ---
if ! printf '%s\n' "$VERSION" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; then
  fail "'$VERSION' is not a semantic version (X.Y.Z); a beta is the same X.Y.Z with B4APP_FLAVOR=beta."
fi
MARKETING_VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' project.yml | head -1)
CODE_VERSION=$(sed -n 's/.*public static let current = "\(.*\)".*/\1/p' Sources/Coordinator/Version.swift)
if [ -z "$MARKETING_VERSION" ] || [ -z "$CODE_VERSION" ]; then
  fail "Cannot read the current version from project.yml (MARKETING_VERSION) and Sources/Coordinator/Version.swift."
fi
if [ "$VERSION" != "$MARKETING_VERSION" ]; then
  fail "Version $VERSION does not match MARKETING_VERSION $MARKETING_VERSION in project.yml; bump it first."
fi
if [ "$MARKETING_VERSION" != "$CODE_VERSION" ]; then
  fail "MARKETING_VERSION $MARKETING_VERSION in project.yml and Version.swift's $CODE_VERSION disagree; package.sh names the zip with the second."
fi
if [ ! -f "$CASK_TEMPLATE" ]; then
  fail "Missing the cask template $CASK_TEMPLATE."
fi

DIRTY=$(git status --porcelain)
if [ -n "$DIRTY" ]; then
  if [ "$DRY_RUN" = 1 ]; then
    echo "Note: the working tree is dirty; a real run would refuse."
  else
    fail "The working tree is dirty; commit or stash first, so the release is the commit it is tagged on."
  fi
fi
HEAD_SHA=$(git rev-parse HEAD)
BRANCH="agent-workspace-$VERSION"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/b4app-release.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
TAP="$WORK/homebrew-tap"

# step <command…>: print the command, then run it unless this is a dry run.
step() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  if [ "$DRY_RUN" = 0 ]; then "$@"; fi
}

echo "==> 0. Preflight$([ "$DRY_RUN" = 1 ] && echo " (a dry run prints the network checks and runs none of them)")"
if [ "$DRY_RUN" = 1 ]; then
  PUSHED=$(git branch -r --contains "$HEAD_SHA" 2>/dev/null | head -1 || true)
  if [ -z "$PUSHED" ]; then
    echo "Note: $HEAD_SHA is on no remote branch; a real run would refuse, since the tag is created on it."
  fi
  echo "+ git fetch --quiet origin   # then HEAD must be on a remote branch"
  echo "+ gh auth status"
  echo "+ gh release view $TAG --repo $SOURCE_REPO   # must not exist"
  if [ "$FLAVOR" = prod ]; then
    echo "+ gh repo view $TAP_REPO --json viewerPermission   # must be WRITE, MAINTAIN, or ADMIN"
    echo "+ gh repo clone $TAP_REPO <tmp>/homebrew-tap"
    echo "+ git -C <tmp>/homebrew-tap ls-remote --exit-code --heads origin $BRANCH   # must not exist"
    echo "+ git -C <tmp>/homebrew-tap switch -c $BRANCH"
  fi
else
  if [ -z "${B4APP_SIGN_IDENTITY:-}" ]; then
    fail "B4APP_SIGN_IDENTITY must name a Developer ID Application identity; a release is always signed and notarized."
  fi
  if [ "${B4APP_SKIP_NOTARIZE:-0}" = 1 ]; then
    fail "B4APP_SKIP_NOTARIZE=1 is set; a release is always notarized."
  fi
  # Fetch first, so a stale remote-tracking ref cannot vouch for a commit the remote lacks.
  step git fetch --quiet origin
  if [ -z "$(git branch -r --contains "$HEAD_SHA" 2>/dev/null | head -1 || true)" ]; then
    fail "$HEAD_SHA is on no remote branch; push it first, since gh creates the tag $TAG on it."
  fi
  command -v gh >/dev/null || fail "gh is not installed (brew install gh)."
  gh auth status >/dev/null 2>&1 || fail "gh is not signed in; run gh auth login."
  if gh release view "$TAG" --repo "$SOURCE_REPO" >/dev/null 2>&1; then
    fail "The release $TAG already exists on $SOURCE_REPO."
  fi
  if [ "$FLAVOR" = prod ]; then
    # The tap must exist and be writable before anything goes public: a release with no cask pull
    # request is half a release. Clone it and cut the branch now, so step 4 only edits and pushes.
    PERMISSION=$(gh repo view "$TAP_REPO" --json viewerPermission --jq .viewerPermission 2>/dev/null || true)
    case "$PERMISSION" in
      ADMIN|MAINTAIN|WRITE) ;;
      "") fail "Cannot see $TAP_REPO (gh repo view failed); create the tap first (docs/release.md) and check gh auth." ;;
      *) fail "You have $PERMISSION access to $TAP_REPO; pushing the branch needs WRITE." ;;
    esac
    step gh repo clone "$TAP_REPO" "$TAP"
    # ls-remote exits 0 when the branch exists, 2 when it does not, and something else on an error.
    status=0
    git -C "$TAP" ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1 || status=$?
    case "$status" in
      2) ;;
      0) fail "The branch $BRANCH already exists on $TAP_REPO; merge or delete it first." ;;
      *) fail "Cannot list the branches of $TAP_REPO (git ls-remote exited $status)." ;;
    esac
    step git -C "$TAP" switch -c "$BRANCH"
  fi
fi

# render_cask <from> <to>: copy the cask with this release's version and hash, and check that each
# line was set exactly once.
render_cask() {
  sed -E \
    -e "s/^( *version )\"[^\"]*\"/\\1\"$VERSION\"/" \
    -e "s/^( *sha256 )\"[0-9a-f]{64}\"/\\1\"$SHA256\"/" \
    "$1" > "$2"
  if [ "$(grep -c "^ *version \"$VERSION\"" "$2")" != 1 ] || [ "$(grep -c "^ *sha256 \"$SHA256\"" "$2")" != 1 ]; then
    fail "$1 has no single version line and sha256 line to set."
  fi
}

echo "==> Releasing the $FLAVOR flavour, version $VERSION, tag $TAG$([ "$DRY_RUN" = 1 ] && echo " (dry run)")"

echo "==> 1. Package, sign, and notarize"
step env B4APP_FLAVOR="$FLAVOR" ./Scripts/package.sh
if [ "$DRY_RUN" = 0 ] && [ ! -f "$ZIP" ]; then
  fail "package.sh did not produce $ZIP."
fi

echo "==> 2. SHA-256 of $ZIP"
if [ -f "$ZIP" ]; then
  SHA256=$(shasum -a 256 "$ZIP" | awk '{print $1}')
  if [ "$DRY_RUN" = 1 ]; then
    echo "$SHA256  $ZIP (the existing file; a real run rebuilds it, so the hash will differ)"
  else
    echo "$SHA256  $ZIP"
  fi
else
  # Only a dry run gets here. A placeholder in the shape of a hash keeps the rendered cask valid.
  SHA256=$(printf '0%.0s' {1..64})
  echo "$ZIP does not exist yet; a dry run never builds it. Using a placeholder: $SHA256"
fi

echo "==> 3. GitHub release $TAG on $SOURCE_REPO"
if [ "$FLAVOR" = prod ]; then
  step cp "$ZIP" "$WORK/$STABLE_ZIP_NAME"
  step gh release create "$TAG" "$ZIP" "$WORK/$STABLE_ZIP_NAME" \
    --repo "$SOURCE_REPO" --target "$HEAD_SHA" --title "$TITLE" --generate-notes --latest
else
  step gh release create "$TAG" "$ZIP" \
    --repo "$SOURCE_REPO" --target "$HEAD_SHA" --title "$TITLE" --generate-notes --prerelease
fi

if [ "$FLAVOR" = prod ]; then
  echo "==> 4. Pull request on $TAP_REPO"
  # The preflight cloned the tap and cut the branch ($TAP, $BRANCH).
  if [ "$DRY_RUN" = 1 ]; then
    # Show the edit on the template, in a scratch directory.
    render_cask "$CASK_TEMPLATE" "$WORK/agent-workspace.rb"
    echo "The cask would read, from the tap's own copy or $CASK_TEMPLATE when the tap has none:"
    grep -E '^ *(version|sha256) ' "$WORK/agent-workspace.rb" | sed 's/^/    /'
  else
    mkdir -p "$TAP/Casks"
    if [ -f "$TAP/$CASK_PATH" ]; then
      render_cask "$TAP/$CASK_PATH" "$WORK/agent-workspace.rb"
    else
      render_cask "$CASK_TEMPLATE" "$WORK/agent-workspace.rb"
    fi
    cp "$WORK/agent-workspace.rb" "$TAP/$CASK_PATH"
  fi
  step git -C "$TAP" add "$CASK_PATH"
  step git -C "$TAP" commit -m "agent-workspace $VERSION"
  step git -C "$TAP" push -u origin "$BRANCH"
  step gh pr create --repo "$TAP_REPO" --head "$BRANCH" \
    --title "agent-workspace $VERSION" \
    --body "Agent Workspace $VERSION: https://github.com/$SOURCE_REPO/releases/tag/$TAG (sha256 $SHA256)."
else
  echo "==> 4. Skipped: the tap carries only the prod cask"
fi

if [ "$DRY_RUN" = 1 ]; then
  echo "Dry run: nothing was built, published, or pushed."
else
  echo "Released $TAG. Merge the tap pull request to publish the cask."
fi
