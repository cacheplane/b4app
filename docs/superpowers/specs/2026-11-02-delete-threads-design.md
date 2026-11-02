# Deleting threads

Owner-approved direction from a brainstorm on 2026-11-02.

## Why

The owner deletes a thread for privacy: "Sometimes I just want to ask some questions and it's not something that I want 'my ai' to remember about me."

In b4app, delete means two things: **do not display it, and do not use it for personal memory**. Personal memory is built today by Codex and Claude from their own past sessions, and may later be built by b4app itself.

Delete does not mean destroying the data everywhere. The hub never deletes data unless the owner asks for a full delete, which will be built separately and much later (D-089). Kept data may be used, cleaned, for analysis and improvement, as AI providers commonly do.

For the runtimes, the owner's words: "We issue the delete command for the thread and let them handle it … IF their api/cli supports deletion, we do it and honor it as best as we can." How each runtime builds its memory is not b4app's concern.

## Goals

1. **Delete a thread from the Mac or the iPhone.** It disappears from the sidebar, search, the project groups, and every device's list. An open view of it closes.
2. **Delete the runtime's copy.**
   - Codex: `thread/delete` on the app-server (codex-cli 0.166.0 schema: params `{ threadId }`).
   - Claude Code: remove the session's transcript, `~/.claude/projects/<project folder>/<sessionId>.jsonl` (under `CLAUDE_CONFIG_DIR` when set), and its subagent folder `<sessionId>/` if present. This is what the Claude desktop app does: it has no CLI command to call, and runs `find … -name <sessionId>.jsonl -exec rm -f {} +` itself.
   - B4: `DELETE /threads/:id` (returns 204).
3. **Keep the thread on the hub and on the Mac, marked deleted.** It is never shown and never used for personal memory by anything b4app builds. Anything that later reads threads for memory must skip deleted ones.
4. **Confirm first, with no undo.** Undo can't be honest once the runtime has deleted its side, and a "restored" thread could never be continued.

## Non-goals

- Undo, a "Recently deleted" list, or restoring a deleted thread.
- A full delete that removes the data from the hub. That is the owner's separate, later project.
- Deleting several threads at once.
- Deleting projects or connections; this is threads only.
- Changing Archive, which stays the gentle "out of sight" option.

## Anti-goals

- **A deleted thread showing up anywhere**: a list, search, a project count, an attention badge, a widget, or a notification.
- **A hard delete of thread data on the hub.**
- **Telling the person the runtime's copy is gone when it isn't.** If the runtime delete has not happened yet, b4app keeps trying, and Diagnostics says so.
- **A delete that destroys data b4app does not own** beyond the thread's own runtime record: never a project folder, never the Claude project directory, only that session's files.

## Decided

### Experience

- **Mac:** Delete… in the thread's "…" menu and its context menu in the sidebar.
- **iPhone:** swipe a row left to Delete, and Delete in the open thread's "…" menu.
- **The confirmation** is an alert:
  - Title: `Delete "<title>"?`
  - Message: "It's removed from this app and from <Codex | Claude Code | the B4 server>. You can't undo this."
  - Buttons: Cancel, and Delete in the destructive style.
  - While a turn is running the message adds "Its running turn will be stopped."
- **After confirming,** the thread disappears at once on that device, and from the others as soon as they sync.

### How a delete flows

1. **The device marks the thread deleted:** a new synced column, `threads.userDeletedAt` (an ISO timestamp, null when not deleted).
   - It is phone-writable, so the phone can delete through the mirror and the hub, just as it renames or archives today.
   - It merges by clock like the other phone-writable thread columns.
   - Once set, nothing clears it (no undo).
   - This is a column update, not a row delete, so the hub keeps the thread, its turns and its items without relying on the soft-delete work.
2. **Every list and read filters out deleted threads:**
   - the coordinator's `thread.list` and snapshot;
   - the attention order;
   - search;
   - project folders and counts;
   - the phone mirror's reads.

   `thread.read` of a deleted thread answers `notFound`.
3. **The Mac deletes the runtime's copy:** when it sets the column itself, or when it pulls a phone's delete. A running turn is interrupted first.
4. **Retries** (my call after the builder check, from the owner's "if their api/cli supports deletion, we do it"). The runtime delete has three outcomes:
   - **Done.** The runtime deleted the thread, or says no such thread exists. A B4 `404` is treated as "already gone".
   - **Not supported, which is final.** The runtime has no delete:
     - Codex answers method-not-found (older than 0.166.0);
     - a B4 server answers `405`;
     - the connection is disabled;
     - its target changed, so the thread's runtime is no longer reachable through it.

     b4app records it once and stops trying.
   - **Unreachable, which is retried.** The runtime is offline, a timeout, a `5xx`. Retries run on the connection's checks and at coordinator start, with backoff.

   Diagnostics lists deletes still waiting and those not supported, by runtime, with no thread titles. The alert names the runtime only when the connection's runtime is known to support delete. Otherwise it reads "It's removed from this app. You can't undo this."

### Data

The Mac (coordinator) keeps the thread row and its turns, display items and drafts, hidden. This follows the owner's "do not display and do not use", not "erase". The phone's mirror may drop a deleted thread's rows from its local cache; that cache is a copy, not the hub.

### Compatibility

There is no gating for older hubs or app builds (the owner, 2026-11-02: "we have no users, we can make all breaking changes and we do not need backwards compat"). The hub, the Mac and the phone are updated together. A phone or hub from before this change would miss deletes, and that is accepted, not handled.

### Naming

The synced column is `userDeletedAt`, not `deletedAt` (my call). The soft-delete work (D-089, `0009_soft_delete`, unmerged) adds a hub-internal `deleted_at` to every synced table, with the opposite meaning for snapshots: that row is left out, while a `userDeletedAt` thread is still sent, so phones learn it is gone. Two near-identical names would invite mistakes.

Decision and migration numbers are chosen at build time after checking every open branch, not only main: the soft-delete branch holds D-089 and hub migration 0009, and the sign-in branch holds D-089 to D-111 and hub migrations 0005 and 0007.

## Left to the builder

- Where the pending runtime delete is recorded (a local-only table or column on the Mac) and the retry schedule.
- The protocol shape:
  - a `thread.delete` command (Mac and relay), or `thread.update` with `deleted: true`;
  - the event that tells clients a thread is gone (`thread.updated` carrying `userDeletedAt`, or a dedicated kind).
- Migrations:
  - the Mac migration adding `threads.userDeletedAt`;
  - the hub's: `TableSpec` columns, `PHONE_WRITABLE` and `CLOCKED` in `writable.rs` and `SyncColumns` in Swift, together;
  - the mirror schema version;
  - the contract fixture, if touched, with both suites.
- The Claude transcript path:
  - reuse `ClaudeAdapter.transcript(sessionId:under:)`;
  - delete only `<sessionId>.jsonl` and `<sessionId>/` inside `projects/<one folder>/`;
  - refuse any path outside it, as the desktop app's own pattern check does.
- What Codex's `thread/delete` requires when the thread is loaded (unsubscribe first or not), verified against the generated schema and the fake app-server.
- Fixture support:
  - `fake-codex.py` answers `thread/delete`;
  - `fake-b4.py` answers `DELETE /threads/:id`;
  - a Claude transcript fixture to delete.
- Decision numbers. Check main's highest first; numbers collide often.
