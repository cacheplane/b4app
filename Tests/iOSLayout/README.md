# iOS navigation and banner regression tests

Run `./Scripts/test-ios-layout.sh` from the repository root. It needs Xcode, an installed iOS 26 Simulator runtime, and XcodeGen. The script selects an available iPhone (preferring an already booted one), generates its test project under `.build/iOSLayout`, and leaves an `.xcresult` bundle there with screenshots. CI runs it after the app builds.

The fixture app compiles the shipped `WorkspaceRootView` and `SyncBanner` over an in-memory mirror and fake relay. Its banner reads an `@Observable` status, as the app's reads `MirrorHost`, and its fake hub greets every link the relay opens and answers its pings, so a runner that stalls the app does not leave a stale banner or "Connecting to the hub…" behind. The tests wait for a screen's title and then for a hittable notice before judging it, since a pushed thread's banner exists in accessibility before it can be hit. It never accesses the owner's account, Keychain, hub, mirror, or installed app. Its extra target is separate from the shipping app targets.

Coverage includes populated, empty, archived, unmatched-search, and scrolled thread lists; thread detail, the new-thread composer, and its no-ready-runtime fallback; Connect your Mac; sign-in and onboarding; sync failure, stale-sync, relay refusal, account notice, Mac-offline and action-error notices; healthy and recovered states; portrait, landscape, accessibility text, and dark mode. The tests tap a thread and return, use search, and check banner clearing on home and detail. The home checks include the profile, filter, search, and new-thread controls.

Horizontal alignment checks measure the 16 pt page gutter on home and thread connection notices and the home composer. On both composer screens they compare the rendered picker-label ink with the draft text's 32 pt leading edge (16 pt outside plus 16 pt inside the field). Menu labels and plain labels expose different accessibility hit bounds, so those bounds alone cannot prove visible text alignment.

Navigation titles are checked in their rendered screenshots as well as accessibility and geometry. UIKit can report a large title as present even when a top safe-area notice prevents its text from being drawn. List headers must remain below navigation controls as the title expands or collapses.

To target a device or retain results at a chosen location:

```sh
B4APP_LAYOUT_DESTINATION='platform=iOS Simulator,id=<device UUID>' \
B4APP_LAYOUT_RESULTS=/tmp/banner-layout.xcresult \
  ./Scripts/test-ios-layout.sh
```

Extra arguments go to `xcodebuild`, for example `'-only-testing:WorkspaceLayoutTests/BannerLayoutTests/testListBannerKeepsLargeTitleAndToolbarVisible()'`. Include the parentheses and quote the entire argument. The script rejects a run that executes zero tests. These are fixture layout checks, not a physical-device or live-hub integration gate.
