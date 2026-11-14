# Dense Composer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** At dense density on the Mac, the composer shows the field, Send, and one muted line saying where and with what the next message runs, in place of the row of pickers.

**Architecture:** A pure value, `ComposerSummary`, builds the line's words from a draft or a thread; `ComposerSummaryLine` draws it. `ComposerView` and `NewThreadView` draw the line instead of `ComposerPickerRow` when `WorkspaceModel.denseComposer` is true. One new catalog command opens the system folder panel, which today is reachable only through the picker row's place palette.

**Tech Stack:** Swift, SwiftUI (`Sources/WorkspaceUI`), Swift Testing (`Tests/WorkspaceUITests`), the snapshot suite.

**Spec:** `docs/superpowers/specs/2026-11-12-density-and-user-settings-design.md`, "Part 4: a dense composer". Read D-207, D-209, D-210, D-214, D-218 and D-223 in `docs/decisions/` first.

## What the palette already offers (read on main, 2026-11-13)

The spec asked this plan to name the commands it found. All are in `Sources/WorkspaceUI/Palette/CommandCatalog.swift`:

| Picker | New thread | Thread |
|---|---|---|
| Place | `draft.environment`, "Choose where it starts…", `/environment` (lists environments, their folders, "No folder") | fixed; none |
| Runtime and model | `draft.runtime`, "Choose runtime and model…", `/model` | `thread.model`, "Choose model…", `/model` |
| Permission | `draft.permission`, "Choose permissions…", `/permissions` | `thread.permission`, "Choose permissions…", `/permissions` |

Missing: the place palette's "Choose folder… ⌘O" (the system folder panel, `NewThreadView.choosingFolder`) has no command. Hiding the row without one would leave no way to start in a folder that is not yet an environment, which the spec's anti-goals forbid. Task 2 adds it.

## Global Constraints

- The Mac only. On iOS (phone and iPad) the pickers stay at either density and there is no summary line (spec, builder's calls). `denseComposer` is `false` on iOS.
- The line is text, not a control: no button, no hover, no menu, no tap. It opens nothing.
- The field, Send, the turn row and relay lines above the field, and the new-thread status line stay at either density.
- The line names, in the pickers' order: the place, the runtime and model, the permission. Parts are joined by `" · "` (U+00B7 with a space each side).
- In a thread the place is left out. On the new-thread screen the place is what the picker shows, "No folder" when there is none.
- The permission is named only when it is not the default (`permission != nil`); never for B4.
- One line. When it does not fit, the place truncates in the middle; the runtime and the permission keep their full width.
- VoiceOver reads it as one static text: "Runs in b4app with Claude Code, Opus".
- `WorkspaceUI` talks only to `WorkspaceClient`. LLA tokens only (`LLA.Color.muted`, `LLAFont.caption`).
- No hub, coordinator, mirror or wire change; no migration.
- Commits end with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.
- Before each commit: `swift format lint --strict --recursive Sources Tests Apps Package.swift`.

## Rulings made in this plan (the planner's calls; the owner may change them)

1. **A blocked reason does not take the row.** The spec gives the row to "Starting…" and a failed send. `NewThreadDraft.blockedReason` ("No ready connection can start a thread in this environment.") is a third thing the status line shows, and it is about the place, so in dense it is drawn on its own line under the summary and the summary stays.
2. **In a thread the line is always shown.** A thread's refused send and its turn row are above the field already; nothing under the field competes for the row.
3. **"Choose folder…" is a command, `draft.chooseFolder`, with `/browse`**, offered on the Mac's new-thread draft and unavailable on a Mac that relays through the hub (as the palette's footer button is disabled). No global shortcut: ⌘O stays the place palette's own key.
4. **No new shortcut for model or permission.** The spec says "a keyboard shortcut or the command palette"; ⇧⌘P and `/` in the field reach all of them.
5. **A draft with no connection** reads "No runtime" where the runtime would be.
6. **If the runtime and permission alone are wider than the row** (the narrowest window, a long connection label), they truncate at the tail after the place has gone to its floor. The spec's "never" cannot hold below that width.

## Review Focus

1. A remote B4 draft: the place reads "No folder", the runtime is the agent's start label, no permission.
2. A thread whose environment is gone or never loaded, and a B4 thread: no place in the line, B4 shows the route's label only.
3. A place name far longer than the row: it is cut in the middle and the runtime and permission are whole.
4. "Starting…" and a failed start replace the line and the line returns after; a blocked reason does not replace it.
5. At normal density, and on iOS at either density, nothing changes: the picker row is drawn and the line is not.

---

### Task 1: `ComposerSummary`, the line's words

**Files:**
- Create: `Sources/WorkspaceUI/NewThread/ComposerSummary.swift`
- Modify: `Sources/WorkspaceUI/NewThread/ComposerPickerRow.swift` (its two `placeText` functions and `runtimeLabel` forward to the new statics; no behaviour change)
- Test: `Tests/WorkspaceUITests/ComposerSummaryTests.swift`

**Interfaces:**
- Produces:

```swift
struct ComposerSummary: Equatable {
  var place: String?       // nil in a thread
  var runtime: String      // "Claude Code · Opus"; a B4 agent's start label; "No runtime"
  var permission: String?  // nil when as configured, and for B4
  var text: String { get }    // the parts that exist, joined by " · "
  var spoken: String { get }  // VoiceOver's sentence

  @MainActor static func draft(_ draft: NewThreadDraft, in model: WorkspaceModel) -> ComposerSummary
  @MainActor static func thread(_ thread: ConversationThread, in model: WorkspaceModel) -> ComposerSummary
  @MainActor static func placeText(_ draft: NewThreadDraft) -> String
  @MainActor static func placeText(_ thread: ConversationThread, in model: WorkspaceModel) -> String
  @MainActor static func runtimeText(_ connection: Connection?, model chosen: String?, in model: WorkspaceModel) -> String
}
```

- `spoken`: `"Runs in <place> with <runtime>"` (thread: `"Runs with <runtime>"`), the runtime's `" · "` read as `", "`, then `", <permission> permissions"` when there is one. With no connection: `"Runs in <place>, no runtime"`.

- [ ] **Step 1: Write the failing tests** in `ComposerSummaryTests` (use the model and draft builders `NewThreadDraftTests` and `PaletteTests` already use; permission labels from `RuntimeOptions.permissions(for:)`, never typed by hand):

  - `aDraftNamesThePlaceTheRuntimeAndTheModel`: environment "b4app" (one folder), Claude Code, model `opus` → `text == "b4app · Claude Code · Opus"`, `permission == nil`, `spoken == "Runs in b4app with Claude Code, Opus"`.
  - `aDraftWithNoModelSaysDefault`: `text` ends `"Claude Code · Default"`.
  - `anEnvironmentWithSeveralFoldersNamesTheFolder`: place is `"b4app · Hub"`.
  - `aChosenFolderIsNamedByItsLastComponent`: `draft.chooseFolder("/Users/x/scratch")` → place `"scratch"`.
  - `noFolderIsSaid`: `selectNoFolder()` → `text` starts `"No folder · "`.
  - `aRemoteB4DraftHasNoFolderAndNoPermission`: place `"No folder"`, runtime is `model.startLabel(for:)`, `permission == nil`.
  - `thePermissionIsNamedOnlyWhenItIsNotTheDefault`: with `selectPermission(first.id)` → `text` ends `" · \(first.label)"` and `spoken` ends `", \(first.label) permissions"`; with `nil` the label is absent.
  - `aDraftWithNoConnectionSaysNoRuntime`: `runtime == "No runtime"`, `spoken == "Runs in b4app, no runtime"`.
  - `aThreadLeavesThePlaceOut`: `place == nil`, `text == "Claude Code · Sonnet"`, `spoken == "Runs with Claude Code, Sonnet"`.
  - `aThreadsOwnPermissionIsNamed`, `aB4ThreadIsItsRoutesLabelAlone`, `aThreadWhoseConnectionIsGoneSaysNoRuntime`.
  - `thePickerRowAndTheLineAgree`: for one draft and one thread, `ComposerPickerRow`'s place text equals `ComposerSummary.placeText`.

- [ ] **Step 2: Run** `swift test --filter ComposerSummaryTests`. Expected: does not compile (`ComposerSummary` undefined).
- [ ] **Step 3: Implement `ComposerSummary`**, moving the bodies of `ComposerPickerRow.placeText(_:)` (both) and `runtimeLabel.full` into the statics, and make the row call them.
- [ ] **Step 4: Run** `swift test --filter "ComposerSummaryTests|NewThreadDraftTests|PaletteTests"`. Expected: pass.
- [ ] **Step 5: Commit** `feat(ui): the words of the dense composer's line`.

### Task 2: "Choose folder…" as a command

**Files:**
- Modify: `Sources/WorkspaceUI/Palette/CommandCatalog.swift`, `Sources/WorkspaceUI/WorkspaceModel.swift`, `Sources/WorkspaceUI/NewThread/NewThreadView.swift`, `Sources/WorkspaceUI/Palette/PaletteModel.swift` (only if a switch over `CommandID` there must name the new id)
- Test: `Tests/WorkspaceUITests/PaletteTests.swift`

**Interfaces:**
- Produces: `CommandID.draftChooseFolder = CommandID("draft.chooseFolder")`; `WorkspaceModel.chooseFolderRequest: Int` (`public internal(set)`, starts 0).
- Definition: title `"Choose folder…"`, symbol `"folder.badge.plus"`, aliases `["browse", "open folder", "other folder"]`, slash `"browse"`, argument `.none`.

- [ ] **Step 1: Write the failing tests**:

  - `theDraftOffersChooseFolderOnTheMac`: on macOS `commands(for: .draft)` contains `.draftChooseFolder` directly after `.draftEnvironment`, for a B4 draft too; on iOS (`#if os(iOS)`) it does not.
  - `chooseFolderAsksTheNewThreadViewForThePanel`: `run(.draftChooseFolder, target: .draft)` returns `.completed` and `chooseFolderRequest` went up by one; the draft is unchanged.
  - `chooseFolderIsOffOnAMacThatRelays`: with `relaysThroughHub`, `availability` is unavailable with reason `"This Mac’s folders cannot be browsed from here."` and `run` leaves `chooseFolderRequest` alone.
  - `slashBrowseIsOfferedInANewThreadDraft`: `slashCommands(for: .draft)` contains it; `slashCommands(for: .thread(id))` does not.
  - the existing catalog test (every id declared once, slash names unique per target) still passes.

- [ ] **Step 2: Run** `swift test --filter PaletteTests`. Expected: the new tests fail to compile.
- [ ] **Step 3: Implement.** Catalog entry; `commands(for: .draft)`; `availability`; `run` bumps `chooseFolderRequest` and returns `.completed("Choose a folder")`. In `NewThreadView` (macOS): `.onChange(of: model.chooseFolderRequest) { placesOpen = false; choosingFolder = true }`.
- [ ] **Step 4: Run** `swift test --filter PaletteTests`. Expected: pass.
- [ ] **Step 5: Commit** `feat(ui): Choose folder is a command of the new-thread draft`.

### Task 3: the line in both composers

**Files:**
- Create: `Sources/WorkspaceUI/NewThread/ComposerSummaryLine.swift`
- Modify: `Sources/WorkspaceUI/WorkspaceModel.swift`, `Sources/WorkspaceUI/ComposerView.swift`, `Sources/WorkspaceUI/NewThread/NewThreadView.swift`, `Sources/WorkspaceUI/DisplaySettingsView.swift`
- Test: `Tests/WorkspaceUITests/DenseComposerTests.swift` (new), `Tests/WorkspaceUITests/SnapshotTests.swift`, `Tests/WorkspaceUITests/DisplaySettingsTests.swift`, `ViewSettingsModelTests`

**Interfaces:**
- Consumes: `ComposerSummary` (Task 1).
- Produces:
  - `WorkspaceModel.denseComposer: Bool`: on macOS `viewSettings.density == .dense`; on iOS `false`.
  - `struct ComposerSummaryLine: View { let summary: ComposerSummary }`, accessibility identifier `"composer-summary"`, `.accessibilityElement(children: .ignore)`, `.accessibilityLabel(summary.spoken)`, trait static text.
  - `DisplaySettingsView.denseDescription` on the Mac: `"Tighter rows for the threads that don’t need you, answers without the steps in a thread, and a composer without its pickers."` The phone's is unchanged.

**Layout of `ComposerSummaryLine`:** an `HStack(spacing: 0)`: the place as `Text(place).lineLimit(1).truncationMode(.middle)`, then one `Text` holding `" · " + runtime` and, when present, `" · " + permission`, with `.lineLimit(1).layoutPriority(1)`, so the place gives way first and the rest is cut at the tail only when it alone does not fit (ruling 6). `LLAFont.caption`, `LLA.Color.muted`, horizontal padding `ComposerField<EmptyView>.textLeading` so its words start under the field's text. In a thread the first `Text` is absent and the second has no leading `" · "`.

**Where it goes:**
- `ComposerView`: `if model.denseComposer { ComposerSummaryLine(summary: .thread(detail.thread, in: model)) } else { ComposerPickerRow(...) }`.
- `NewThreadView.composer`: at dense, in place of the picker row and with the row's `.padding(.top, LLA.Space.s)`: the status (`draft.status`, the existing `new-thread-status` view) when there is one, else the summary line; then, under it, the blocked reason (`new-thread-reason`) when there is one and `notice == nil` (ruling 1). At normal density the body is as today.

- [ ] **Step 1: Write the failing tests** in `DenseComposerTests` (hosted, with the helpers `DenseTranscriptViewTests` uses to find views by accessibility identifier; macOS only, inside `#if os(macOS)`):

  - `denseComposerFollowsTheDensityOnTheMac`: `denseComposer` is false at normal and true at dense.
  - `aDenseThreadComposerDrawsTheLineAndNoPickers`: `composer-summary` is found, `picker-place`, `picker-permission`, `picker-runtime` are not; `send` and `composer` are.
  - `aNormalThreadComposerIsUnchanged`: the three pickers are found, `composer-summary` is not.
  - `aDenseNewThreadDrawsTheLineAndNoPickers` and `aNormalNewThreadIsUnchanged`, likewise.
  - `theLineIsNotAControl`: the hosted line has no button, menu or tap gesture descendant (no `NSButton`/`NSControl` under it; its accessibility role is static text).
  - `theLineChangesWhenACommandChangesTheChoice`: at dense, `await model.run(.draftRuntime, target: .draft, argument: …)` then the line's label names the new runtime, with nothing sent.
  - `startingTakesTheRowAndTheLineReturns`: a draft that is submitting shows `new-thread-status` and no `composer-summary`; once a refusal clears (new choice made), the line is back.
  - `aFailedStartTakesTheRow`: a refused start shows `new-thread-status` in place of the line.
  - `aBlockedReasonSitsUnderTheLine`: a draft with no ready connection shows both `composer-summary` and `new-thread-reason`.
  - `aLongPlaceIsCutAndTheRuntimeIsWhole`: host `ComposerSummaryLine` at 320 pt wide with a 120-character place and a permission; the runtime-and-permission `Text`'s frame width equals its ideal width, and the line's height is one line.
  - In `DisplaySettingsTests`: the Mac's description is the new sentence. In `ViewSettingsModelTests`: nothing on iOS changes (`#if os(iOS)` `denseComposer == false` at dense).

- [ ] **Step 2: Run** `swift test --filter "DenseComposerTests|DisplaySettingsTests"`. Expected: fail to compile.
- [ ] **Step 3: Implement** `denseComposer`, `ComposerSummaryLine`, the two call sites and the description.
- [ ] **Step 4: Add snapshots** to `ListSnapshotTests` as `denseComposers`, both appearances each, 720 pt wide: a dense thread composer; a dense thread composer with a non-default permission; a dense new-thread screen; a dense new-thread screen with "Starting…"; a dense new-thread screen with a blocked reason; a dense new-thread screen 420 pt wide with a long place; and the normal new-thread screen for comparison. Look at every image: the line's first letter is under the field's first letter, and the height the composer loses at dense is the picker row's hover padding only.
- [ ] **Step 5: Run** `swift test --filter "DenseComposerTests|DisplaySettingsTests|ViewSettingsModelTests|SnapshotTests|DetailMinimumSizeTests"`. Expected: pass.
- [ ] **Step 6: Commit** `feat(ui): a dense composer shows one line where the pickers were`.

### Task 4: records and gates

**Files:**
- Create: `docs/decisions/D-NNN-a-dense-composer.md` (number from `Scripts/docs-index.sh --next`, taken when the pull request opens), `docs/verification/YYYY-MM-DD-a-dense-composer.md`
- Modify: `AGENTS.md` (extend the sentence about density in "Layout": dense also replaces the Mac composer's picker row with `ComposerSummaryLine`, built by `ComposerSummary`), `docs/milestones.md`, the spec (a dated "Built" note under Part 4 naming the commands found and the six rulings)

- [ ] **Step 1: Write the decision** in the log's style (read D-223 first): amends D-218 and D-223; what dense now does to the composer; the Mac only; the six rulings above, each marked as the builder's call; the new command; what is not built (shortcuts for model and permission, the phone).
- [ ] **Step 2: Run the gates** and record each result in the verification file, with what was not checked (the running app, VoiceOver, the narrowest window on a real screen):

```bash
swift format lint --strict --recursive Sources Tests Apps Package.swift
swift test
xcodebuild build -project B4App.xcodeproj -scheme B4App-macOS -destination 'platform=macOS'
xcodebuild build -project B4App.xcodeproj -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'
./Scripts/test-ios-layout.sh
Scripts/docs-index.sh --check
```

Expected: lint silent; every test passes; both builds succeed; the iOS layout tests pass unchanged (the phone keeps its pickers); the docs check passes.

- [ ] **Step 3: Commit** `docs: the dense composer's decision, milestone and gate record`.
