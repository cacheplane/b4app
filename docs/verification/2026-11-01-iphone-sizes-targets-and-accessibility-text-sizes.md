## 2026-11-01: iPhone sizes, targets, and accessibility text sizes (D-060, fixture gates and Simulator)

Run from `blove/ios-mobile-fit` (on `main` at `2e05bad`) on macOS 26.5 with Xcode 26.6; the iPhone 17 Pro Simulator (iOS 26.5) showed the mirror of the Mac's threads through the local Compose hub.

| Check | Command | Result |
| --- | --- | --- |
| Lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Clean |
| Tests | `swift test` | 572 tests in 99 suites pass |
| Mac app | `xcodebuild build -project B4App.xcodeproj -scheme B4App-macOS -destination 'platform=macOS'` | `** BUILD SUCCEEDED **` |
| iPhone app | `xcodebuild build -project B4App.xcodeproj -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | `** BUILD SUCCEEDED **` |
| Mac unchanged | `B4APP_SNAPSHOT_DIR=$TMPDIR/b4snap swift test --filter SnapshotTests` | The sidebar, profile menu, and Settings pages draw at the desktop scale as before (by eye) |
| Phone, default size | Simulator build with team `GJJKL34HCT`, `xcrun simctl ui <udid> content_size large`, screenshots before (`main`) and after | `docs/screenshots/ios-hig-default.png`. Sidebar and thread rows measured 28 pt tall on a 52 pt pitch before and 44 pt on a 44 pt pitch after (selection highlight, 3x screenshot); profile-menu items 28 to 44 pt; body text 15 to 17 pt; one title on the thread instead of two |
| Phone, AX3 | `content_size accessibility-extra-large` | `docs/screenshots/ios-hig-ax3.png`. Before: symbols ran into labels, the avatar and marks stayed small, "completed" broke inside its badge, the command title truncated to "/b…md'". After: titles wrap, the card and header stack, Diagnostics and Connections read label above value, Send drops below the editor |
| Hit regions | Taps 3 pt inside a thread row's top edge on its empty right side, and on a transcript card's padding | The row opened its thread; the card toggled Show/Hide |

Design review (same branch, after the first gates): New thread, Search, the More menu, Settings, and Connections were added to the pass, in light and dark (`xcrun simctl ui <udid> appearance dark`) and at AX3. The fixes are listed under D-060; `docs/screenshots/ios-hig-review.png` shows New thread before and after and the dark Settings and Connections pages. Gates rerun after the fixes: lint clean, `swift test` 572 tests in 99 suites pass, both app builds succeed, the 7 Mac `SnapshotTests` pass. The Hanken navigation titles are computed when the app starts, so a text-size change while it runs takes effect at the next launch (system inline titles barely scale either).

Open: the Connect screen was checked in code only (the phone is joined, and leaving would need a new enrollment code); its fields and button were already 44 pt and now share the 16 pt margin and the phone scale. No `performAccessibilityAudit` UI test exists yet (no XCUITest target).
