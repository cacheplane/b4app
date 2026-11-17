# Plans and task lists in the transcript: design

Date: 2026-11-16. Status: draft for the owner's approval. Nothing here is built.

## Intent

When an agent keeps a plan or a task list, the reader should see the list and how far along it is. Today Codex's plan is dropped before it reaches the app, and Claude Code's and B4's show as raw tool rows that read as noise (defect 10 in `docs/research/2026-11-14-agent-chat-hill-climb.md`). A plan is the agent's own account of what it is doing and what is left, so it is among the most useful things a transcript can show during a long turn.

## What the runtimes send

Read from the code, the Codex 0.166.0 schema (`codex app-server generate-json-schema`) and a recorded Claude Code 2.1.227 transcript. Nothing here was checked against a live session.

| Runtime | Message | Shape |
| --- | --- | --- |
| Codex | `turn/plan/updated` notification | The whole list each time: `threadId`, `turnId`, `explanation` (optional string), `plan` of `{ step, status }`, status `pending`, `inProgress` or `completed`. Dropped by `CodexEventTranslator` today |
| Claude Code | `TodoWrite` tool use | The whole list each time: `todos` of `{ content, status, activeForm }`, status `pending`, `in_progress` or `completed` |
| Claude Code | `TaskCreate`, `TaskUpdate` tool uses | One change each. `TaskCreate` input is `{ subject, description, activeForm }`; its id is only in the result, whose text begins `Task #<n> created successfully`. `TaskUpdate` input is `{ taskId, status, ... }`. Ids count up across the whole session, not per turn |
| B4 | `plan_update` event | The whole list each time: `todos` of `{ content, status }`. Today it becomes a generic row through the translator's unknown-event case |

Codex also has a `plan` thread item, which is plain text (a plan-mode proposal). It is a different thing and is why the new item is not called `plan`.

## Goals

- One row per turn holds the agent's list. It stands where the agent first wrote the list in that turn, and its marks change in place as the work proceeds.
- The row looks the same for all three runtimes.
- The raw rows it replaces (`TodoWrite`, `TaskCreate`, `TaskUpdate`, `TaskList`, `TaskGet`, B4 `plan_update`) are no longer drawn.
- A step is never shown as done unless the runtime said so. A step still in progress when its turn was stopped or failed reads as unfinished, as tool steps do (D-234).
- The phone shows the same row with no new sync work.

## Non-goals

- `ExitPlanMode` and Codex's text `plan` item. They are proposals in prose, not checklists.
- Codex command output while a command runs (the other half of audit row 10). The row stays open for that half.
- A panel pinned above the composer. The owner chose a row in the transcript.
- Editing the list, or acting on a step, from the app.
- Sub-agent work (defect 11).

## Anti-goals

- A second copy of the row after a reconcile (the class of defect D-238 fixed).
- Runtime-specific knowledge in `WorkspaceUI`.
- A list that claims progress the runtime did not report.

## Approaches

- **A. Each adapter writes one shared item (chosen by the owner).** The adapter turns its runtime's shape into one display item per turn with a fixed native id. `SessionService` already replaces an item's payload when the same native id arrives again, so updating in place needs no new storage, no migration, and nothing new in the sync. Cost: three adapter changes, and Claude Code's history import must do the same folding.
- **B. Fold the stored rows in the projection.** `DenseTranscript` would recognise each runtime's rows and draw the latest per turn. Less adapter work, and old threads gain a row, but runtime knowledge moves into the UI, every update stays stored, and Codex needs an adapter mapping anyway.
- **C. A synced table for plans.** Dropped: hub, coordinator and mirror migrations for something an item already carries.

## The item

One `DisplayItem` per turn that has a list.

- `type`: `taskList`. `role`: `tool`. It is not a counted step (`DenseTranscript.isCountedStep` stays false for it).
- Native item id: `tasks:<native turn id>`, so every update in the turn lands on the same row and the row keeps the sequence of its first write.
- Payload:
  - `steps`: array of `{ text, status }`, in the runtime's order. `status` is `pending`, `inProgress` or `completed`. An unknown status is stored as `pending`.
  - `explanation`: optional string (Codex only today).
  - `status`: `completed`, as other finished items carry, so nothing treats the row as an open tool.

Each adapter maps its own words to these three statuses (`in_progress` to `inProgress`). A list with no steps writes nothing; if the turn already has a row, the row is updated to the empty list and the view draws nothing for it.

## The adapters

**Codex.** `turn/plan/updated` becomes one item event with `itemId` `tasks:<turnId>`. Codex's history (`thread/turns/list`) does not carry these notifications as far as the schema shows, so a row written live is not in a later import. See "The snapshot merge" below for what that needs.

**B4.** A named event `plan_update` with a `todos` array becomes the item, `itemId` `tasks:<turnId>`, in place of the generic row. Any other named event keeps today's behaviour. Whether `GET /state` returns the list in history is not known; if it does not, the row is live-only as Codex's is.

**Claude Code.** `ClaudeTurnTracker` holds the session's list.

- `TodoWrite`: the tool use's `todos` replace the list. No `toolUse` row is emitted for the call or its result.
- `TaskCreate`: the step is added as `pending` when the result arrives and gives the id (from the result text, `Task #<n>`). Before the result there is nothing to show, since the step has no id to update later.
- `TaskUpdate`: changes the status, and the text when `subject` is given, of the step with that `taskId`. Status `deleted` removes the step. An update for an id the tracker does not know is ignored.
- `TaskList`, `TaskGet`: no row.
- After each change the tracker emits the whole list as the current turn's item. Because Claude Code's tasks live across turns, a later turn that changes one task gets its own row with the whole list as it then stands; a turn that touches no task gets none.
- A failed result (`is_error`) for any of these changes nothing.

The tracker is made when a session's process starts and dropped when it exits, so every resume and coordinator relaunch would start with an empty list. The folding is therefore one shared function over tool uses and results, used by the live tracker and by the history import, and a resumed session seeds its tracker by folding the session's transcript before the first turn. If the transcript cannot be read the tracker starts empty and unknown ids are ignored.

**Claude Code history** (`snapshotItems`) folds the same tool uses the same way and names the item as the live path does. The live turn id is one the app makes and the transcript does not carry it, so for Claude Code the item is named after the tool use that first changed the list in that turn (`tasks:<tool use id>`), which both paths know. In the transcript a turn begins at a user line that carries text. A reconcile of a thread whose turn wrote a list must add no row: this is the main risk in the design and needs a coordinator test like `reconcilingAClaudeThreadAddsNoSecondCopyOfItsRows`.

## The snapshot merge

`mergeSnapshotItems` keeps a live row the snapshot does not name, but appends it after every snapshot item and renumbers. A Codex or B4 list row would move to the end of the thread on the first history load, and the projection would then draw it as a second group for its turn. The merge changes so that an unmatched live row keeps its place: it is put back directly after the row that stood before it in the stored order (or first, if none did). This applies to every unmatched live row, not only lists, and needs its own `SnapshotMergeTests` cases, including the D-238 cases unchanged.

## What the reader sees

Normal density, in place among the turn's rows:

```
Plan · 2 of 4
✓ Read the adapter
✓ Add the mapping
● Write the tests
○ Update the docs
```

- The header counts completed steps of the total. When Codex gives an explanation it is one muted line under the header.
- Marks are drawn, not text characters: done, in progress (the working mark while the turn runs), pending. Done steps are muted.
- Once the turn is no longer running, a step still `inProgress` is drawn as unfinished, whatever the turn's outcome, and as unknown while the turn is reconciling. This is what `DenseTranscript.settled` does for tool steps today; it works on the item's own `status`, so the list needs the same rule applied to each step. Claude Code often ends a turn with a step in progress and picks it up in the next; the next turn's row shows it running again.
- All steps are drawn; a step's text wraps to at most two lines.
- VoiceOver reads the header as "Plan, 2 of 4 done" and each step as its text and state.

Dense: while the turn runs, the row is drawn after the steps line, as the turn's messages are, so the plan is visible without opening the turn. Once the turn has ended it folds with the other working rows and is seen by opening the line. It is never counted as a step.

## Calls made here, not by the owner

- The item is named `taskList`, with role `tool`.
- Dense shows the row while the turn runs and folds it afterwards.
- The running line (D-239) is not changed to carry "2 of 4".
- `TaskCreate` shows nothing until its result arrives.
- Old threads are not rewritten. Rows a live turn stored before this change stay as generic tool rows, and a reconcile of such a Claude Code thread adds the list row beside them. Nothing hides or removes the old rows; the owner is the only user and has said old surfaces need no compatibility.
- An unmatched live row keeps its place through a snapshot merge (a storage change).
- A resumed Claude Code session rebuilds its list from the transcript.
- A step in progress when its turn ends reads as unfinished even when the turn completed.

## Left to the builder

- Which `EventKind` carries the item (an existing tool kind is expected to do).
- The view's name and file, and its exact spacing and colours within the theme.
- Fixture additions: `fake-codex.py` (a plan update), `fake-claude.py` (`TodoWrite` and the `Task*` pair), `fake-b4.py` already emits `plan_update`.

## Verification

- Adapter tests per runtime from native frames, including the status mapping, an empty list, a failed `Task*` result and an unknown `taskId`.
- A coordinator test that several updates in one turn leave one row, and the Claude Code reconcile test above.
- Projection tests at both densities (running, ended, stopped with a step in progress), corpus ledger rows, and snapshots in light and dark.
- Records by the repository's rules: a decision file, a verification record, `docs/compatibility.md` for the message shapes, `docs/milestones.md`, and audit row 10 marked as half dealt with.
- A live session per runtime is not part of this work and is to be recorded as untested.
