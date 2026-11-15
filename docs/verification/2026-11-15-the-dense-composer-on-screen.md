## 2026-11-15: the dense composer on screen

The on-screen checks `docs/verification/2026-11-13-a-dense-composer.md` left open for D-224, run on `main` 5edf935 (#197 merged). The shipped `WorkspaceRootView` ran in the macOS smoke harness (`Tests/macOSSmoke`, built with `xcodebuild build-for-testing`) against its fixture host (`WorkspaceSmokeHost` with the fake Codex runtime, a private `/tmp/b4smk-*` root), driven by hand with real keys and clicks. Dense was set with `viewSettings.set` on the fixture's socket, since the harness has no Settings window. No installed app, account, Keychain item or LaunchAgent was used.

### Seen

- The line at dense, on the new-thread screen: "No folder · Fixture runtime · Default" under the field, its first letter under the field's; at normal density the picker row is back. In the archived fixture thread: "Fixture runtime · Default", with no place.
- `/` in the field lists `/environment`, `/model`, `/permissions`, `/browse` ("Choose folder"), `/review` and `/compact`. Escape from a command's list of choices returns to the slash list.
- `/browse` with Return clears the field and opens the folder panel; the palette's "Choose folder…" (⇧⌘P) opens it too. The first time, the panel opened behind another app's window and the harness's window list did not show it, so it first looked as if nothing had opened.
- Cancel returns the cursor to the field (typed text lands there). Choosing a folder through Go to Folder returns it too, and the line becomes "work · Fixture runtime · Default".
- At 900 × 600, the minimum window (`LLA.Metrics.minimumWindow`), with the sidebar shown: the line fits on one line in the new-thread screen and in the thread.

### Noticed, not changed

- In the palette, "choose folder" ranks "Choose where it starts…" above "Choose folder…": the first has "folder" as an alias. Down then Return picks the second.
- A folder chosen through the panel is not a row of "Choose where it starts…", so the list marks nothing as current; the line names the folder. The list has been environments and "No folder" since the palette was added (753746a), before D-224.
- The harness launched with `SMOKE_WIDTH=560` throws `NSGenericException` ("needing another Update Constraints in Window pass", from `NSHostingView`'s minimum size) at either density and quits; at 900 it runs at both. The harness asks for a window below the app's own minimum, which the app's windows cannot reach.

### Not checked

- A folder row's path in "Choose where it starts…": it shows only for an environment with more than one folder, and the fixture has none.
- VoiceOver speaking the line (`composer-summary`, `ComposerSummary.spoken`); the accessibility walk used here was cut short before reaching it.
- A long connection label at the narrowest width; the fixture's label is short.
