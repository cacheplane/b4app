## 2026-11-12: The place palette

D-209: the "composer palette" step of the thread list and environments design. The Mac chooses where a new thread starts in a palette over the veiled new-thread view; the phone in a "Start in" sheet; the picker row loses its chevrons and takes a hover fill; the heading reads "Let's get started". Branch `blove/place-palette`, from `main` 7e11980.

### Gates

- `swift test --filter PlacePaletteTests`: 5/5 (rows and indented folders, the check, the filter over names and paths, "~" paths, the highlight). They failed to build before `PlacePalette` existed.
- `NewThreadDraftTests.paletteRowsChooseTheirPlace`: an environment's row starts in its first folder, a folder row in that folder, the check follows, "No folder" clears it.
- `swift test --filter WorkspaceUITests`: 468 tests, one failing, `AppleSignInTests.appleSheetSaysItHasNoWindow` (Apple's framework returned `AuthorizationError` 1000 instead of the "no window" refusal). It passes alone, and a clean checkout of `main` 7e11980 fails it the same way in the full suite (462 tests, the same two issues), so it was failing before this change; not investigated further here.
- `./Scripts/test-ios-layout.sh` on this checkout's Simulator (iPhone 17 Pro, iOS 26.5): 16/16. `testHealthyComposerJourney` now taps the place picker on the new-thread screen, finds the "Start in" sheet with the environment, "No folder" checked and no "Choose folder…", chooses the environment, and reads its name on the label. The picker row's alignment checks pass without chevrons. The first run failed to build the harness from derived data left by a run on an older `main`; it passed from clean derived data.
- Rendered (`B4APP_SNAPSHOT_DIR=… swift test --filter SnapshotTests/newThreadComposer`): `newThreadComposer` (the centred heading, the chevron-less row) and the new `placePalette` (the palette over the veiled view, the filter, the rows with paths, the footer), light and dark, looked over by eye. The fixture's environments each have one folder, so the indented rows were not rendered.
- `xcodebuild` of `B4App-iOS` for the Simulator and of `B4App-macOS` (Debug), `swift format lint --strict`, `Scripts/docs-index.sh --check`.

### Not checked

- The palette in the running Mac app. The Debug build has the Local flavour's bundle id, and the owner's installed Local app was running, so it was not launched beside it. Motion (the veil's fade, the rise, the sliding highlight, the label's fade-up), hover, Up and Down, Return, Escape, a click on the veil, ⌘O and the folder panel were not exercised.
- The phone's sheet was checked by the layout test only, not looked at, and not on a device.
