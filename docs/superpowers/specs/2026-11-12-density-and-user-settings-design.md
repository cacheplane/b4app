# Density and per-user settings: design

Date: 2026-11-12. Status: draft for the owner's approval. Nothing here is built.

## Intent

The owner wants one switch that makes the whole app leaner, not only the sidebar. In a thread, "leaner" means less of the agent's work on screen: the question and the answer, with the steps one click away. In the composer it means the field alone. In the sidebar it means the tight rows that exist today under the name "Tiny".

Two things have to be put right for that to work:

- The app's settings must belong to a user. Today the three list settings are one row per organisation on the hub, so in a shared organisation only the first user's settings are stored (D-208's known limit). The owner's rule: almost every setting is per user; organisation settings are a separate thing for billing and the like.
- "Small, Tiny, Collapsed, Hidden" is one setting doing two jobs: how tight the rows are, and whether quiet threads are stowed. Density takes the first job; a sidebar setting keeps the second.

## Goals

- A density setting with two levels, normal and dense, on a new "Display" page in Settings. It applies to the sidebar, the thread and the composer, and syncs to the user's other devices.
- A sidebar setting, "Threads that don't need you": Shown, Collapsed or Hidden. It no longer mentions row size.
- A dense thread shows, for each turn, the user's message, one line counting the agent's steps, and the final answer. The line opens to show the steps.
- A dense composer shows the field and Send, and one line of text where the row of pickers was.
- Settings are stored per user within an organisation. A user in two organisations has separate settings in each. One user's settings are never visible to or changed by another.
- The owner's current settings survive the change.

## Non-goals

- Organisation settings (billing and the like). Nothing here builds them; nothing here should make them harder.
- A third density level, or per-surface density. One switch.
- The service that cleans up temporary folders and worktrees. Separate design.
- A new command palette. The dense composer relies on the one being built on `blove/b4-command-palette-spec-ba5790` (its decisions are numbered D-213 to D-215 on that branch).
- Changing what the composer remembers per device (last place, runtime, model) or which groups are collapsed. Those stay per device.

## Anti-goals

- A dense thread in which a turn that failed looks the same as one that worked.
- A dense thread that hides something the user must act on: an approval, a question, a failure notice.
- A dense composer with no way to choose where a thread starts, or to change a thread's model or permission.
- A setting that a device silently rewrites because it cannot show it.
- Two users in one organisation overwriting each other's settings, or one seeing the other's.

## Constraints

- No backwards compatibility is needed: the owner is the only user, and old surfaces are replaced outright. Stored values are migrated, not supported side by side.
- Never edit an applied migration (D-178). Each store gets a new one: the hub, the coordinator's store, and the phone's mirror schema.
- `Tests/Fixtures/sync/changes.json` changes only together with both suites that decode it. The hub's and Swift's lists of which columns a phone may write change together.
- `WorkspaceUI` talks only to `WorkspaceClient`.
- LLA: no colour beyond what the list already uses, no uppercase, Reduce Motion respected.
- The phone keeps 44 pt touch targets and Dynamic Type.
- Deploy order when a hub migration is involved: hub first, then the Mac and the phone.

## Terms

- **Settings row**: today's `viewSettings` row, id `view`, holding `arrangement`, `quietThreads`, `showArchived`.
- **Step**: anything in a turn that is not the user's message and not the turn's last agent message: reasoning, tool calls, command output, file changes, interim agent messages.
- **Answer**: the last agent message of a turn.

## Part 1: settings belong to a user

The owner's decisions:

- Settings are per user within an organisation.
- A user in two organisations has separate settings in each.

How, as the builder's call (the owner accepted "carry the user in the row's id"; the builder check then showed where that id should live): the user is carried in the row's id **on the hub only**. Devices keep reading and writing a row whose id is the literal `view`. The hub stores it as `view:<userId>` and translates at its edge: a pushed change to `view` is applied to the pusher's own row, and a pull or snapshot hands that row back as `view`. The hub keeps one keying rule, `(org, id)`, for every synced table, and the per-row clocks, which are keyed by row id, separate by user for free.

Why not rename the row on the devices too: the sync layer has no rename (changes are insert, update or delete, and the change log is append-only), the Mac's store and the phone's mirror are already one per account, a device may not know its real user id yet (the Mac holds a placeholder until the hub's account call answers; the phone's is optional), an older build would keep writing `view`, and exported archives contain `view`. Translating on the hub avoids all five and needs no migration on either device.

What must hold afterwards:

- A device can only ever reach its own user's row. The hub refuses a `viewSettings` change whose row id is anything other than `view` (today it accepts any id, a deferred minor in D-208), so nobody can create or squat on another user's row.
- The owner's existing row keeps its values and clocks: the hub's migration renames the stored row and its clock entries to `view:<its user>`. Entries already in the change log keep the id `view`; since every log read is already limited to the reader's own user and devices still expect `view`, a new or reinstalled device that replays the log sees the same settings. (The builder confirms a full replay ends on the migrated values and adds a test for it.)
- A second user in the same organisation gets their own row, stored durably; a resync returns it, and neither user's pull contains the other's.
- The table keeps its name. It will hold more than list settings, so new fields and new code refer to it as the user's settings.

Left to the builder: exactly where the translation sits in the hub's push, pull and snapshot code; the shared fixture's new cases (two users in one organisation; a refused foreign id).

## Part 2: two settings where there was one

The owner's decisions:

- **Density** is its own setting: normal or dense. A switch on a "Display" page in Settings. App-wide. Synced per user.
- **Threads that don't need you** is a separate sidebar setting with three values, one choice: Shown, Collapsed, Hidden. Synced per user. It works at either density.

Migration of today's `quietThreads` value:

| Stored today | Density | Threads that don't need you |
|---|---|---|
| small | normal | shown |
| tiny | dense | shown |
| collapsed | normal | collapsed |
| hidden | normal | hidden |

Defaults for a new user: normal, shown.

Where they appear:

- **Settings → Display** (a new page, on the Mac and the phone): one switch, "Dense", with a line saying what it changes: tighter rows in the sidebar, answers without the steps in a thread, and a composer without its pickers. The page's name is the builder's suggestion.
- **Sidebar view options**: the group "Threads that don't need you" lists Shown, Collapsed, Hidden. It stays disabled in the "By environment" arrangement, as today.

What density means in the sidebar:

- Normal: today's "Small" rows.
- Dense: today's "Tiny" rows (20 pt, 11 pt type, 8 pt marks), on the Mac. They now apply wherever a quiet row is drawn: the lower list when it is shown, and the rows revealed by opening Collapsed or Hidden. The top list, the threads that need you, keeps full rows at either density. (Builder's call; say so if the owner wants the whole sidebar tight.)
- On the phone rows keep their 44 pt height at either density. The old fallback, "Tiny shows as Collapsed on the phone", goes: there is no value left that a device cannot show.

## Part 3: a dense thread

The owner's decisions, made looking at four renderings of one sample thread:

- A finished turn shows the user's message, one line that counts the steps, and the answer.
- The line can be opened to show the collapsed activity.

The count line:

- Reads "4 steps" or, when any step failed, "4 steps, 1 failed", then "Show". Opened, the last word is "Hide". Small muted type; "failed" in the danger colour.
- A turn with nothing but its answer has no line. A turn with reasoning or interim messages but no counted step still gets a line, reading "Show working", so nothing the agent produced is unreachable. (Builder's call.)
- Opening it shows that turn's steps in place, as the normal density draws them (the reasoning and tool cards, the interim messages), between the user's message and the answer. Closing it puts the line back. Whether a turn is open is remembered while the thread is on screen, not stored. (Builder's call.)
- What counts as a step for the number: tool calls, command runs and file changes. Reasoning and interim messages are shown when opened but not counted, so the number matches what the agent did. A step is "failed" when its status says failed. (Builder's call.)
- A turn with no answer (it failed or was stopped before one) shows its line and its note, and nothing in the answer's place. System items are drawn as at normal density.
- Opening a turn must not move what the user is looking at: the line stays where it is on screen and the steps open beneath it. Today's transcript pins its bottom edge when its height changes, which would push the line away; the builder handles that for this case.

What dense never hides:

- A pending approval or question, which is drawn outside the transcript's items today and stays there.
- "Turn failed." and "Turn stopped." notes, and the notice for a turn whose outcome is unknown. Today these notes are drawn after all the items, at the end of the transcript. In dense each is drawn with its own turn, after the count line, so a failed turn reads as failed where it happened. Normal density keeps today's placement. (Builder's call.)
- The phone's own message that is still on its way.

A turn that is still running, in dense: the user's message, the line, and the agent's messages as they stream. The line names what the agent is doing ("swift test", "Searching b4"), or reads "Working" between steps and "Waiting for you" when the turn waits on an approval or a question; it does not count. When the turn ends, the line counts, its last agent message is the answer and earlier ones fold into the steps. (Builder's call; this is the part most likely to need a look in the running app.)

Amended 2026-11-13, after research into how other tools draw an agent's progress (the owner's b4run and hashbrown designs, threadplane, and shipping coding agents), approved by the owner:

- The running line names the current step, as above. It used to read "3 steps so far".
- A step the user declined is counted apart from a failed one: "4 steps, 1 declined", with "declined" in muted type.
- Plan updates, todo lists and other items that are not tool calls are shown when the line is opened but are not counted, and one that follows the answer does not hide it.
- A turn that has ended never shows a step as still running; such a step reads "stopped".
- Items that belong to no turn (a thread read from history) are grouped at each user message and drawn as ended turns, so a thread from history is dense too. They used to be drawn as at normal density.
- An opened turn stays where it is on screen until the reader scrolls back to the end, sends a message or shows another thread; until then the transcript does not follow the stream.

Normal density is today's transcript, unchanged.

## Part 4: a dense composer

The owner's decisions:

- In dense, the row of pickers under the composer is not shown, in a thread and on the new-thread screen.
- Choosing where a thread starts, and changing a model or permission, is done with a keyboard shortcut or the command palette.

- In place of the pickers, the dense composer shows one muted line saying where and with what the next message will run, such as "b4app · Claude Code · Opus". It is text, not a control: it opens nothing, and the command palette and shortcuts do the changing. (Owner, 2026-11-12, answering the builder check: without it a new thread could start in a folder the user never saw.)

The line in detail, as the builder's calls:

- It names what the hidden pickers would show, in their order: the place, the runtime and model, and the permission. On the new-thread screen the place is the folder or environment the thread will start in ("No folder" when there is none). In a thread, where the place cannot change, it is left out.
- The permission is named only when it is not the default, so the usual line stays short and an unusual permission stands out.
- It is one line. When it does not fit it truncates in the middle of the place, never the runtime or permission.
- It changes as soon as a command changes a choice, so the palette's effect is visible without sending.
- VoiceOver reads it as one static text, "Runs in b4app with Claude Code, Opus".
- It shares its row with the status line: while there is a "Starting…" or a failed send to explain, that takes the row, and the line returns after.

What stays at either density: the field, Send, and the line under the field that says "Starting…" or why a send did not go through. That line is the only place a failed send explains itself. (Builder's call.)

This part depends on work that is not on main. The command palette is being built on `blove/b4-command-palette-spec-ba5790`. The composer has three pickers: the place, the permission, and the runtime with its model. The dense composer needs a command for each: one that opens the place picker for a new thread, one that changes the permission, and one that changes the runtime and model (for a thread, the model only, as today). Until those exist, hiding the pickers would strand the user, which is an anti-goal.

So: parts 1 to 3 can be built and shipped without part 4. In that state dense leaves the composer's pickers in place. Part 4 follows the command palette's merge, and its plan names the commands it found there. On the phone, where there is no command palette, the pickers stay at either density unless the owner says otherwise.

## Build order

The builder's suggestion, each its own pull request:

1. Per-user settings rows (part 1). Hub, coordinator store, mirror, fixture. No visible change.
2. The two settings and the Display page (part 2), with the sidebar reading density. Hub, both stores, the UI.
3. The dense thread (part 3). UI only.
4. The dense composer (part 4), after the command palette lands. UI only.

Steps 1 and 2 each carry a hub migration and so a hub-first deploy; the builder may combine them into one if that halves the deploys without making the change harder to review.

## Builder's calls

These are the designer's decisions, not the owner's. Change them if the code argues otherwise, and say so.

- The row id `view:<userId>` on the hub rather than a user column in the key.
- The table keeps the name `viewSettings`.
- The Settings page is called "Display" and the switch "Dense".
- Dense tightens quiet rows only; the top list keeps full rows.
- Steps counted are tool calls, command runs and file changes.
- Open and closed turns are remembered only while the thread is on screen.
- The status line under the composer stays at either density.
- The phone keeps its pickers at either density, and so has no summary line.
- The dense composer's summary line: what it names, that the permission shows only when it is not the default, how it truncates, and that it gives its row to the status line. That the line exists is the owner's decision.
- The user's id is carried in the row id on the hub only; devices keep `view`.
- "Show working" for a turn with reasoning but no counted step; failed and stopped notes drawn with their turn in dense.
- The storage shape of the two new fields, and whether `quietThreads` is reused for the three-way value or replaced.

## Questions the builder may meet

- Whether a second user can join an organisation today. The design does not depend on the answer; the tests for part 1 should make a second user in a fixture either way.
- What a dense thread shows for a B4 agent's turn, whose items may not be tool calls. The designer's guess: the same rule, with whatever is not the answer counted as steps only if it is a tool call.
- Whether the command palette's branch has changed the composer's picker row by the time part 4 starts. Read it then.

## Deploying

No backwards compatibility is kept, so the hub, the Mac and the phone move together, hub first. A build from before part 2 that is still running afterwards keeps writing the old `quietThreads` values; they are stored, and a current build reads a value it does not know as the default without rewriting it. Part 2's hub migration converts the stored value (the table in part 2) and gives the new column a clock, so the converted value is not overwritten by the first device that pushes.

## What was verified

A fresh reader checked this document against the code as the builder who must plan from it. That check corrected part 1 (the hub accepts any row id today; there is no rename in the sync layer; a device's user id can be a placeholder), added the third picker to part 4, and found that failure notes are drawn at the end of the transcript, not with their turn.


The four transcript renderings the owner chose from were drawn with the app's real transcript rows through the snapshot harness (throwaway branch `spike/transcript-detail`, not pushed); the count line and its "Show" were sketches and did nothing. Facts about today's settings (the four values, where they apply, the one-row-per-organisation limit, the Settings pages) were read from the code and D-208 on 2026-11-12. The command palette branch was read only by its commit titles and file list. Nothing in this design has been run.
