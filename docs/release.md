# Releasing the Mac app

The Mac app ships only as a notarized Developer ID zip on GitHub Releases (`cacheplane/b4app`) and through the Homebrew cask in `cacheplane/homebrew-tap` (D-062). The owner runs the release from the Mac that holds the Developer ID identity and the notary profile (D-039); there is no release workflow in CI.

## What a release publishes

| Flavour | Tag | Release | Assets |
| --- | --- | --- | --- |
| `prod` | `mac-v<version>` | latest | `Agent-Workspace-<version>.zip`, and the same file as `Agent-Workspace.zip` |
| `beta` | `mac-v<version>-beta` | prerelease | `Agent-Workspace-Beta-<version>.zip` |

`https://github.com/cacheplane/b4app/releases/latest/download/Agent-Workspace.zip` always serves the newest prod build, which is why prod attaches the stable name; the download page on b4.run links it. A beta is a prerelease, so it never becomes "latest". The `local` flavour is never released.

## Releasing

Once, outside the script: the identity and the notary profile from `Scripts/package.sh`'s header (`security find-identity -v -p codesigning`, `xcrun notarytool store-credentials b4app …`), the Developer ID provisioning profiles under `~/.b4app/signing/`, and `gh auth login` as someone who can create releases on `cacheplane/b4app` and push to `cacheplane/homebrew-tap`.

1. Bump the version in `project.yml` (`MARKETING_VERSION`) and `Sources/Coordinator/Version.swift`, merge it, and make sure the commit is pushed. The script refuses a version that is not `X.Y.Z`, that differs from either file, or that disagrees between them.
2. Preview: `./Scripts/release-mac.sh <version> --dry-run` (and with `B4APP_FLAVOR=beta`). Read the commands it prints.
3. Release the beta first if you want a soak: `B4APP_FLAVOR=beta B4APP_SIGN_IDENTITY="Developer ID Application: … (TEAMID)" ./Scripts/release-mac.sh <version>`.
4. Release prod: `B4APP_SIGN_IDENTITY="Developer ID Application: … (TEAMID)" ./Scripts/release-mac.sh <version>`.
5. Merge the pull request the prod run opens on `cacheplane/homebrew-tap`. Until it merges, `brew install --cask cacheplane/tap/agent-workspace` still installs the previous version.
6. Check the result: `brew reinstall --cask cacheplane/tap/agent-workspace`, open the app, and run `agent-workspace doctor --json` from the linked binary.

A real run refuses unless the tree is clean, `HEAD` is on a remote branch (the tag is created on that commit), `B4APP_SIGN_IDENTITY` is set, `B4APP_SKIP_NOTARIZE` is not, `gh` is signed in, and the release does not already exist. It checks all of that before the several-minute build. Then, in order:

1. `Scripts/package.sh` builds, signs with the identity, notarizes, staples, and zips.
2. It hashes the zip with `shasum -a 256`.
3. `gh release create` publishes the tag and the assets on `cacheplane/b4app`.
4. Prod only: it clones the tap, sets `version` and `sha256` in `Casks/agent-workspace.rb` (starting from `Packaging/homebrew/agent-workspace.rb` when the tap has no cask), pushes the branch `agent-workspace-<version>`, and opens a pull request.

If a step fails after the release exists, finish by hand: the zip and its hash are under `dist/`. Delete a bad release with `gh release delete mac-v<version> --cleanup-tag --repo cacheplane/b4app`; the script will not recreate a tag that exists.

## What the dry run checks

`--dry-run` runs every check that needs no network and prints each command it would run, with the SHA-256 of the zip. It never builds, never runs `gh`, never runs `git push`, and does not require a clean tree or a pushed commit (it says when a real run would refuse). It does check:

- the flavour is `prod` or `beta` (`local` is refused);
- the version is `X.Y.Z` and equals `MARKETING_VERSION` and `Version.swift`;
- the cask template exists, and that `version` and `sha256` each appear once to be rewritten (it renders the template into a scratch directory and prints the two lines).

If `dist/` already holds the zip for that flavour and version, the dry run hashes it; that file is from an earlier build and a real run rebuilds it, so the hash will differ. Otherwise it prints a placeholder of 64 zeros and says so.

## Creating the tap (once, owner only)

The script clones `cacheplane/homebrew-tap` but does not create it. Creating a public repository is outward-facing, so the owner does it:

1. Create the public repository `cacheplane/homebrew-tap` (the `homebrew-` prefix is what lets `brew tap cacheplane/tap` find it), with a `main` branch and a README.
2. Add `Casks/agent-workspace.rb` from `Packaging/homebrew/agent-workspace.rb` in the first commit, with its `version` and `sha256` set to the first prod release's, or leave it out and let the first prod run add it in its pull request.
3. Check it: `brew tap cacheplane/tap`, `brew audit --cask --online cacheplane/tap/agent-workspace`, `brew style cacheplane/tap`.

Users install with `brew install --cask cacheplane/tap/agent-workspace`. The cask installs `Agent Workspace.app` and links the bundled CLI as `agent-workspace`; it requires macOS 26 (Tahoe) and zaps `~/Library/Application Support/b4app` and the coordinator's LaunchAgent plist.

The draft in this repository is the source of truth for the cask's shape. After the tap exists, change both: edit the tap's copy (the script rewrites only `version` and `sha256` there) and this template.
