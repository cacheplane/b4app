# M6: package and accept the personal v0

Date: 2026-10-31. Spec section 13 (M6) and 14 (acceptance). Decision D-004 promised a LaunchAgent "when the bundle layout exists"; this is that layout.

## Intent

Brian opens `Agent Workspace.app` from Finder or Spotlight, the coordinator is already running or starts for him, the installed `codex`, `claude`, and `node` are found without a shell, the CLI on his PATH talks to the same coordinator, and quitting the window never ends his work. The deliverable is the `.app`, the scripts that make it, the documentation to install and use it, and an honest acceptance record.

## Constraints found on the target Mac

- No code-signing identity is installed (`security find-identity -v -p codesigning` lists none). Builds are signed ad hoc (D-006). Developer ID signing and notarisation stay open until Brian installs a certificate; the package script takes `B4APP_SIGN_IDENTITY` for that day.
- Without a provisioning profile the Keychain stays file-based (D-008); nothing changes.
- Xcode 26.6, macOS 26.5, XcodeGen 2.46.

## Bundle layout

```
Agent Workspace.app/Contents/
  MacOS/Agent Workspace                       the SwiftUI app
  Helpers/b4app-coordinator                   the standalone coordinator (SwiftPM release build)
  Helpers/agent-workspace                     the CLI
  Library/LaunchAgents/com.cacheplane.b4app.coordinator.plist
  Resources/                                  icon, WorkspaceUI bundle (fonts, brand)
```

`Scripts/package.sh` builds the two executables with `swift build -c release`, builds the app with `xcodebuild` in Release into `.build/DerivedData`, assembles `dist/Agent Workspace.app`, writes the LaunchAgent plist, signs helpers then the app (`codesign --force --options runtime` only when an identity is given; ad hoc otherwise), and zips it. `Scripts/install-cli.sh` symlinks the bundled CLI into `~/.local/bin` (or a directory given as the first argument).

## Coordinator lifecycle (replaces the in-process default)

Order in the app's `CoordinatorHost`:

1. Connect to the socket; if a coordinator answers, use it (unchanged).
2. If the running bundle has the LaunchAgent plist, register `SMAppService.agent(plistName:)`. When its status is `.enabled`, wait up to five seconds for the socket and connect. When it is `.requiresApproval`, surface one sentence in the link status ("Allow Agent Workspace in System Settings › Login Items so conversations keep running when the window closes") and fall through.
3. Host in-process as today (Xcode runs, unapproved agent, non-bundled builds).

The plist runs `Contents/Helpers/b4app-coordinator` with `RunAtLoad`, `KeepAlive: { SuccessfulExit: false }`, `LimitLoadToSessionType: Aqua`, `ProcessType: Interactive`, and stdout and stderr redirected to the data directory's `logs/coordinator.launchd.log`. The coordinator's own lock still makes a second start exit 0, so an app-hosted coordinator and a launchd one never both serve.

Quit (D-032): when launchd hosts the coordinator the app owns nothing and quits at once; local turns and owned servers continue. The dialog's wording already covers the in-process case. `docs/decisions.md` records the amendment.

Upgrade: a new app version beside a running older coordinator is detected by comparing `doctor.coordinator.version` with the app's own version; the link status then offers "Restart coordinator", which the CLI also exposes as `agent-workspace coordinator restart` (sends SIGTERM to the lock's pid, waits for the socket to close, and lets launchd or the next client start the new one). The coordinator version string becomes the package's `MARKETING_VERSION` injected at build.

## CLI discovery of the coordinator

`Launcher.executablePath` adds, after `B4APP_COORDINATOR_PATH` and the sibling: `../Helpers/b4app-coordinator` relative to the CLI (so the bundled CLI finds the bundled coordinator through the symlink's resolved path), then `/Applications/Agent Workspace.app/Contents/Helpers/b4app-coordinator` and the same under `~/Applications`.

## Finder launch (A01)

`ExecutableLocator` already searches `~/.local/bin`, Homebrew, `/usr/local/bin`, npm-global, Volta, Bun, `/usr/bin`. It gains nvm (`~/.nvm/versions/node/*/bin`, newest first), fnm (`~/.local/share/fnm/aliases/default/bin`, `~/Library/Application Support/fnm/aliases/default/bin`), and `/opt/homebrew/opt/node/bin`, since `node` is what the B4 server needs and nvm is how this Mac installs it. The launchd environment has no `PATH` beyond `/usr/bin:/bin:/usr/sbin:/sbin`, so this list is what a packaged app sees.

## Documentation

README gains: Install (package, copy to `/Applications`, first launch and the Login Items approval, CLI symlink), First sign-in (Codex and Claude through their own CLIs), B4 environment setup (register a project, env file, routes), Upgrade, Uninstall (what to delete: the app, `~/Library/Application Support/b4app`, the LaunchAgent registration). `docs/milestones.md` M6 and `docs/verification.md` M6 with the acceptance matrix A01 to A18, each row marked pass, fixture-only, or open with the reason.

## Non-goals

A DMG or installer, auto-update, Developer ID (no certificate), App Store, iOS packaging (the iOS app has no transport), any spec section 15 feature.
