# Research: all-Swift monorepo and app stack (verified 2026-10-30)

Environment: macOS 26.5 (Apple Silicon), Xcode 26.6 (17F113), Swift 6.3.3. Xcode 27.x (Swift 6.4) exists but requires macOS 26.6+, so this machine is on Swift 6.3 until macOS is updated. https://developer.apple.com/support/xcode/

## Toolchain

- `// swift-tools-version: 6.2` is the minimum for `.defaultIsolation(...)` (SE-0466) and swift-subprocess 1.x. Set `swiftLanguageModes: [.v6]` explicitly; Swift 6 mode means strict concurrency with errors. https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md
- Approachable concurrency for all targets: `.enableUpcomingFeature("NonisolatedNonsendingByDefault")` and `.enableUpcomingFeature("InferIsolatedConformances")`. Default `MainActor` isolation only for UI and app targets; libraries, the daemon, and the CLI stay nonisolated. https://useyourloaf.com/blog/approachable-concurrency-in-swift-packages/

## Repo structure

One umbrella `Package.swift` at the repo root with library targets, two executable targets (coordinator, CLI) and tests, plus **XcodeGen 2.46.0** (2026-07-16) generating a gitignored `.xcodeproj` from `project.yml` for the two thin app targets. Reasons: `project.yml` is small text that agents edit safely, generation is scriptable in CI, and no `pbxproj` conflicts. https://github.com/yonaskolb/XcodeGen/releases

Rejected: hand-maintained `.xcodeproj` with synchronized folders (target and setting edits still touch pbxproj); Tuist (heavier DSL, server features, overkill for one developer); SwiftPM-only (cannot produce a `.app` with Info.plist, entitlements and asset catalogs, and simulator builds need SDK flag hacks). https://forums.swift.org/t/swift-package-manager-use-of-info-plist-use-for-apps/6532

## Deployment targets

macOS 26 and iOS 26 only. Personal app, both installed, and it removes every availability shim for Liquid Glass APIs (`glassEffect`, `GlassEffectContainer`, `ToolbarSpacer`). Apple recommends `NavigationSplitView` for sidebar and detail. Share views through one UI library; use `#if os(macOS)` only for windows, commands and toolbar placement. https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass

## Libraries

| Need | Choice | Version | Notes |
| --- | --- | --- | --- |
| SQLite | GRDB.swift | 7.11.1 (2026-06-18) | `DatabasePool` opens WAL automatically, `DatabaseMigrator`, Codable records, works in a plain executable. https://github.com/groue/GRDB.swift/releases |
| Unix socket server and client | SwiftNIO + swift-nio-extras | 2.104.0 (2026-10-06), extras 1.35.x | `ServerBootstrap.bind(unixDomainSocketPath:cleanupExistingSocketFile:...)` and `ClientBootstrap.connect(unixDomainSocketPath:)` return `NIOAsyncChannel`; `LineBasedFrameDecoder` for NDJSON. Network.framework supports `NWEndpoint.unix` but has a 104-byte path limit and no framing or backpressure story. https://github.com/apple/swift-nio/blob/main/Sources/NIOPosix/Bootstrap.swift |
| Child processes | swift-subprocess | 1.0.2 (2026-10-16) | Source-stable since 1.0.0 (2026-08-04), Swift 6.2+. `run(.path(...), input: .inputWriter, output: .sequence, error: .sequence)`, `teardownSequence = .gracefulShutDown`, `createSession`, `environment: .inherit.updating([...])`. Avoids Foundation.Process pipe deadlocks. https://github.com/swiftlang/swift-subprocess/releases |
| HTTP and SSE | URLSession `bytes(for:)` | system | `.lines` drops blank lines (the SSE delimiter), so parse bytes directly; `timeoutIntervalForRequest` is an idle timeout. https://developer.apple.com/forums/thread/725162 |
| Keychain | Security framework | system | Data-protection keychain needs a provisioning profile and access group; ad-hoc local builds fall back to the file-based keychain where re-signed binaries prompt. https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains |
| CLI | swift-argument-parser | 1.8.2 | `AsyncParsableCommand`, `ExitCode`. https://github.com/apple/swift-argument-parser/releases |
| Format | `swift format` (bundled) | 6.3 | `.swift-format` at the root; `swift format lint --strict --recursive`. SwiftLint 0.65.1 optional later. |
| Tests | Swift Testing | Xcode 26 | `@Test`, `#expect`; XCTest only for XCUITest. |
| Logging | `os.Logger` | system | Privacy annotations; daemon logs visible in Console. |

## Running the coordinator

Packaged target state (M6): `SMAppService.agent(plistName:)` with the plist in `Contents/Library/LaunchAgents/` and `BundleProgram` pointing at the embedded coordinator; launchd enforces one instance per user, restarts on crash, survives window close, and needs no shell PATH. For the shell PR the coordinator is a library hosted by the macOS app in-process and a standalone executable the CLI can spawn. Singleton lock with `flock(LOCK_EX | LOCK_NB)` on a lock file before binding. https://developer.apple.com/documentation/servicemanagement/smappservice

## App Sandbox

A sandboxed app can only run helpers embedded in its bundle, cannot spawn the user's `claude` or `codex`, and its container paths exceed the Unix socket path limit. Disable App Sandbox (not App Store). Non-sandboxed apps need no entitlements to spawn processes or open sockets; for distribution use Developer ID, Hardened Runtime and notarization; locally sign ad hoc. iOS cannot run a daemon or reach a Mac socket; it needs a relay designed later. https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app

## CI

`macos-latest` is `macos-26` with Xcode 26.6 default. Pin with `sudo xcode-select -s /Applications/Xcode_26.6.app`. Cache `.build` and `~/Library/Caches/org.swift.swiftpm` keyed on `Package.resolved`. Jobs: `swift build`, `swift test`, `brew install xcodegen && xcodegen generate`, `xcodebuild build` for macOS and for `generic/platform=iOS Simulator`. https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md

Unverified: Tuist's current version; exact simulator device names on the CI image; ad-hoc signed keychain prompt behavior.
