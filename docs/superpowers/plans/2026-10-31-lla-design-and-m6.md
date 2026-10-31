# LLA visual system and M6 packaging: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle both apps in the LiveLoveApp visual system, then package the macOS app with a bundled coordinator and CLI, a LaunchAgent, Finder-safe runtime lookup, docs, and the acceptance record.

**Architecture:** A `Theme` folder inside `WorkspaceUI` owns every token and shared control; views only compose them. Packaging is a shell script over `swift build -c release` and `xcodebuild`; the app's `CoordinatorHost` prefers a launchd-hosted coordinator and falls back to in-process hosting.

**Tech Stack:** SwiftUI, CoreText font registration, SwiftPM resources, `SMAppService`, XcodeGen, `codesign`.

**Specs:** `docs/superpowers/specs/2026-10-31-lla-visual-system-design.md`, `docs/superpowers/specs/2026-10-31-m6-package-and-accept-design.md`.

## Global Constraints

- Palette, radii, type scale, and state colours exactly as the visual-system spec's tables.
- No literal colours, radii, or font names outside `Sources/WorkspaceUI/Theme/`.
- Accessibility identifiers already asserted by tests are unchanged.
- `WorkspaceUI` keeps importing only SwiftUI, Observation, UniformTypeIdentifiers, CoreText, WorkspaceProtocol, WorkspaceClient (plus AppKit/UIKit for dynamic colours only).
- `swift format lint --strict` clean; `swift test` green; both app schemes build.

## Review Focus

1. A font that fails to register must leave text readable in the system font (no blank labels): `LLAFontsTests.fallsBackWhenMissing`.
2. Dark mode must keep 4.5:1 for body text and 3:1 for muted text on `bg`; checked by `LLAColorTests.contrast`.
3. The mark must render from the vendored SVG, not a hand-typed glyph: `LLAMarkTests.parsesIconIntoClosedPath`.
4. A packaged app launched by `open` with an empty PATH must still find `node`, `codex`, `claude` through the fallback list: `ExecutableLocatorTests.findsNvmNode`.
5. Two coordinators must never serve at once when launchd and the app race: the lock test in `CoordinatorTests` plus the live A01 row.

---

### Task 1: Theme module (tokens, fonts, mark, controls)

**Files:** Create `Sources/WorkspaceUI/Theme/{LLATheme,LLAFonts,LLAMark,LLAControls}.swift`; modify `Package.swift` (resources); test `Tests/WorkspaceUITests/ThemeTests.swift`.

**Interfaces produced:** `LLA.Color.*`, `LLA.Radius.*`, `LLA.Space.*`, `LLAFont.sans/mono/display/title/body/small/caption`, `LLAFonts.register() -> Bool`, `LLAMark(variant:)`, `LLAButtonStyle` (`.llaPrimary/.llaSecondary/.llaDanger/.llaLink`), `LLACard`, `Hairline`, `LLABadge`, `LLAStateDot`, `LLASectionHead`, `LLAEmptyState`, `.llaField()`.

- [ ] Tests: `parsesIconIntoClosedPath`, `registersBundledFonts`, `fallsBackWhenMissing`, `contrast`.
- [ ] Implement; `swift test --filter ThemeTests` passes; commit.

### Task 2: Sidebar and root

**Files:** `WorkspaceRootView.swift`. Mark header, text surface rows, thread rows with `LLAStateDot`, archived section, link status.

### Task 3: Thread detail, transcript, composer, approvals, continuity banner

**Files:** `ThreadsView.swift`, `TranscriptView.swift`, `ComposerView.swift`, `RuntimeRequestView.swift`.

### Task 4: Connections, Local servers, Diagnostics, New thread sheet

**Files:** `ConnectionsView.swift`, `LocalServersView.swift`, `DiagnosticsView.swift`, `NewThreadSheet.swift`.

### Task 5: App icon

**Files:** `Scripts/make-app-icon.swift`, `Apps/Shared/Assets.xcassets/AppIcon.appiconset`, `project.yml`. Verify: both schemes build; `Contents/Resources/AppIcon.icns` exists in the built app.

### Task 6: Verify and open the design PR

`swift format`, `swift test`, both app builds, screenshot via the built app, PR against `feat/m5-daily-use-recovery`.

### Task 7: Finder-safe runtime lookup

**Files:** `Sources/WorkspacePlatform/Executables.swift`, `Tests/WorkspacePlatformTests`. Add nvm, fnm, Homebrew node paths; test with a fake HOME.

### Task 8: Bundled coordinator discovery and `coordinator` CLI commands

**Files:** `Sources/Coordinator/Launcher.swift`, `Sources/AgentWorkspaceCLI/Main.swift`. `coordinator status`, `coordinator restart`; tests in `CoordinatorTests`.

### Task 9: LaunchAgent hosting in the app

**Files:** `Apps/macOS/B4App/B4AppMac.swift` (`CoordinatorHost`), `Apps/macOS/B4App/com.cacheplane.b4app.coordinator.plist`, `Sources/WorkspaceUI/WorkspaceModel.swift` (link note), `project.yml`. Verified live in Task 12.

### Task 10: Package and install scripts

**Files:** `Scripts/package.sh`, `Scripts/install-cli.sh`. Verify: `dist/Agent Workspace.app` launches from Finder with the helpers inside and ad hoc signatures valid (`codesign --verify --deep`).

### Task 11: Documentation and decisions

README sections, `docs/decisions.md` D-036 to D-039, `docs/milestones.md` M6, `docs/compatibility.md` versions.

### Task 12: Click-through and acceptance record

Drive the packaged app on screen: connections, new thread, a fixture Codex turn, approval card, stop, rename, pin, archive, continuity banner, Quit dialog, Local servers. Record A01 to A18 in `docs/verification.md` with pass, fixture-only, or open.
