## 2026-11-12: The place palette gives way to New thread and search

D-210, on `blove/place-palette-fixes` from `main` 9e21141 (D-209's palette).

### Gates

- `swift test --filter "PlacePaletteTests|NewThreadDraftTests|SnapshotTests|DetailMinimumSizeTests|MacTopBarTests"`: 84 tests in 6 suites passed. `theFilterMatchesTheShownPath` and `theEmptyLineSaysWhy` are new and failed to build before the change.
- `swift format lint --strict --recursive Sources Tests Apps Package.swift`, `xcodebuild` of `B4App-macOS` and of `B4App-iOS` for the Simulator, and `Scripts/docs-index.sh --check`.
- The full `swift test` and `./Scripts/test-ios-layout.sh` were not run here; CI runs both.
- A read-only review of the commit found every item in the code and nothing critical. Its one code suggestion (typing counts as a key move for the hover rule) is in.

### Seen in the Local app

Packaged from 4211175 and installed over the owner's Local app (its data copied to `~/.b4app/backups/b4app-local-pg-20261112-071327`), light appearance, four single-folder environments, driven in the background:

- The place label opens the palette over the veiled view; the sidebar is not veiled. The filter field reads "Filter" to accessibility.
- Typing "run" left one row, and the field stayed where it was (the same y before and after).
- File › New Thread with the palette open closed it, and text typed next went into the composer.

On the parallel build (not this code, but the same handlers for search and the same key path for the arrows), the day before: Up and Down, Return, Escape, a click on the veil, and search closing the palette were seen working.

### Not seen

Hover and the hover rule, Tab, ⌘O and the folder panel, the footer's "No folder", search closing this build's palette, Return and Escape on this build (D-209's `onSubmit` path), motion and Reduce Motion, VoiceOver, the no-environments line outside its test, environments with several folders, and anything on the phone.
