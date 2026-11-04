## 2026-10-31: LiveLoveApp visual system

Target: the same MacBook Pro. Screen control for the app was requested and declined in this session, so the window was not clicked; every surface was rendered offscreen instead, by `SnapshotTests` over a real coordinator with the fixture Codex and Claude runtimes, in both appearances (`docs/screenshots/threads-{light,dark}.png`; the full set lands wherever `B4APP_SNAPSHOT_DIR` points).

### Automated

| Check | Command | Result |
| --- | --- | --- |
| Format lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Tests | `swift test` | Pass: 245 tests in 55 suites (5 new in `ThemeTests`: SVG parse and fit, font registration, fallback without fonts, palette contrast in both appearances) |
| macOS app | `xcodebuild build -scheme B4App-macOS` | Pass; `AppIcon.icns` and the `WorkspaceUI` resource bundle with the three fonts are inside the app |
| iOS app | `xcodebuild build -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | Pass |
| Offscreen render | `B4APP_SNAPSHOT_DIR=<dir> swift test --filter SnapshotTests` | Pass: threads (pending approval, running and waiting dots, pinned and archived rows), empty threads, connections, local servers, diagnostics, light and dark |

### Seen in the renders

- The mark draws from the vendored SVG; Hanken Grotesk and JetBrains Mono are the faces in use; headings carry the tight tracking.
- The accent appears only on the "Waiting for you" badge and dot and on link buttons; running is an ink dot with a faint ring; failures use the danger red; everything else is ink and grey.
- Cards are hairline-bordered with radius 16, buttons are pills, no shadow or gradient anywhere; dark mode keeps every pairing above 4.5:1.
- The composer grows with its draft and the request card sits above it in the 720 pt reading column.

### Clicked later the same day (screen control granted)

The packaged window at first showed only its toolbar: the root's ideal height was 1458 pt in an 800 pt window (an infinite-height frame inside a split-view column) and the window centred the oversized view, so the sidebar and detail sat outside the visible area; `IdealSizeTests` now pins the root's ideal height. After the fix, seen and driven on screen: the sidebar (mark, surfaces, thread rows, link status), the Threads empty state and its button, the new-thread sheet (connection picker, directory, title, Create), and a thread created on the real Codex connection with the composer, toolbar Rename, Pin, Archive. Still not clicked: hover states, the context menu, the rename alert, the Quit dialog, the continuity banner, a sent turn.
