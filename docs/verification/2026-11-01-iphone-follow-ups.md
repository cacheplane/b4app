## 2026-11-01: iPhone follow-ups (D-060, fixture gates and Simulator)

Run from `blove/iphone-hig-followups` (on `main` at `4552bdb`) on macOS 26.5 with Xcode 26.6, iPhone 17 Pro Simulator (iOS 26.5).

| Check | Command | Result |
| --- | --- | --- |
| Lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Clean |
| Tests | `swift test` | 573 tests in 99 suites pass |
| Mac app | `xcodebuild build … -scheme B4App-macOS -destination 'platform=macOS'` | `** BUILD SUCCEEDED **` |
| iPhone app | `xcodebuild build … -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | `** BUILD SUCCEEDED **` |
| Read-only Settings | Simulator: Settings › Connections and › Local servers | Connections shows its two cards with status and account only, and the sentence about the Mac; no Add section, Check, Sign in, or Re-check runtimes. Local servers shows the sentence and "No projects registered on your Mac."; no Add a project or server controls |
| Titles follow the text size | `xcrun simctl ui <udid> content_size accessibility-extra-large`, then `large`, with the screen open | The open Connections large title grew in place; a thread's inline title measured 140.7 pt wide at Large, 166.0 pt at AX3, and 140.7 pt again after switching back, without leaving the screen |

`docs/screenshots/ios-hig-followups.png`. The Mac's pages are unchanged (`WorkspaceDevice.managesWorkspace` is true there; the server controls moved into a property, same views).
