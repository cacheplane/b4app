# M8b to M8f: the phone as a second keyboard

Date: 2026-10-31. Owner: Brian Love. Status: approved by the owner 2026-10-31.

This document amends `2026-10-31-m8-hub-design.md` (the M8 design). Everything there still holds unless a section below says otherwise. M8a, the read-only mirror, is merged (PR #16) and live-verified with the owner's packaged app and the Simulator.

## Intent

Brian wants "a full remote experience, as if I was sitting in front of the keyboard on my Mac and using the chat". From the phone he wants to continue threads he started on the Mac and start new ones, and to see at a glance which threads need him. The Mac still does all the work; the hub is how the phone reaches it (D-045 still holds: a send to a Mac that is offline is refused, never queued).

What the owner said, in his words where it matters:

- Projects: "A project is associated with a system folder. All threads for the same folder share a project, which the user can optionally rename, it can just default to the repo/folder name … A project can also be manually created, and point to one or more folders."
- "Don't group by project. Simply use project as a filtering mechanism on the home page for mobile."
- Ordering: "always show the thread that needs the user's input at the top, followed in order [by] the latest threads with a full response, then latest threads with tool calling/thinking/progress, then stale threads." Stale is renamed **quiet**: "It's not working anymore and you have already read the latest reply."
- "For desktop, I want this same intelligent ordering within project groupings (simply collapsible header)."
- "Pinning always puts it at the top - it's pinned for a reason."
- Staying reachable: an app preference to keep the system awake, on by default; "start with a single app toggle, no per-thread preference".
- Attention away from the phone: a notification when a thread needs input, and "a native iOS progress widget … showing the top 3 threads and a simple colored circle/icon showing the thread status", accepting that widgets refresh only every so often.
- Order of work: "reorganized thread list, then full chat", proved "using the simulator using the local hub, then we'll deploy, configure apple developer program, and validate broadly."

## Goals, non-goals, anti-goals

Goals:

1. One thread list on the Mac and the phone, ordered by what needs Brian: pinned, then needs input, unread reply, working, quiet.
2. Projects: every thread belongs to the project of its folder; projects can be renamed and created by hand over several folders. The phone filters by project; the Mac groups by project.
3. The phone writes: titles, pins, archive, drafts, read state, and project names, converging with the Mac's edits.
4. The phone holds a full conversation: send, watch the reply stream, answer approvals, stop a turn, start a new thread in a project.
5. The Mac stays reachable while Brian is away, by a single preference that is on by default.
6. The phone tells Brian when a thread needs him (notification) and shows the top three threads on its home screen (widget).
7. All of it proved in the iPhone Simulator against the Compose hub on the Mac before any deployment.

Non-goals (for these slices):

- Deploying the hub off the Mac, TLS, the Apple Developer Program, APNs credentials, and a physical iPhone. That is the next slice after these, as the owner ordered.
- Browsing the Mac's filesystem from the phone. New threads from the phone start in folders projects already know.
- Creating projects or editing their folders from the phone (my call; the phone renames only).
- Per-thread keep-awake, Live Activities, notification preferences, and multi-Mac ownership rules beyond "the thread's own Mac".
- Everything in M8d (accounts, rate limiting `/v1/enroll`) and the original M8e (Helm, SAML, SCIM).

Anti-goals:

- The phone showing a thread as working when its turn ended, or as quiet when an approval is waiting.
- Two devices disagreeing about a title, pin, draft, or read marker after both have synced.
- An edit silently lost because the other device happened to write later on a slower clock.
- A secret, executable path, or pid in a hub row, a notification, or the widget (the M8 rule; `threads.context` and project folder paths sync by the owner's decision, D-046).
- Two orderings: the Mac and the phone must compute the bands with the same code.

## Slices and order

The owner ordered the work: the reorganised list first, then full chat, then attention on the phone, then deployment. The original M8 slice letters are kept where their content survives so existing references stay true:

| Slice | Content | Exit, in the Simulator against the Compose hub |
| --- | --- | --- |
| **M8b, organisation** (this document's detail) | projects, attention ordering, read state, phone writes, HLC and per-column LWW, the coordinator pulls, device-aware rows, M8a's deferred sync items | see "M8b exit" below |
| **M8c, remote chat** | the relay (M8 design), streaming to the phone, approvals, interrupt, new thread from the phone, "Keep the Mac awake" | a conversation held entirely from the Simulator |
| **M8f, attention on the phone** | notifications through a swappable push sender, the home-screen widget | a pending approval notifies the Simulator; the widget shows the top three |
| then: deploy and device | hub off the Mac with TLS, Apple Developer Program, APNs, a real iPhone | the owner's to schedule |
| M8d accounts, M8e deployable | unchanged from the M8 design | unchanged |

M8f is a new letter so that M8d and M8e keep their meaning in `docs/milestones.md` and D-044. Each slice gets its own plan; this document is detailed enough to plan M8b now and M8c and M8f without another design pass, though their plans may surface small calls.

## M8b, organisation

### Projects

A **project** is a named set of folders on one Mac. Every thread whose working directory (`threads.context`) is exactly one of those folders belongs to it.

- **Automatic projects.** When the coordinator creates a thread whose folder belongs to no project, it creates a project for that folder with an empty name; an empty name displays as the folder's last path component (`/Users/blove/repos/b4app` → "b4app"). Brian never has to create a project before starting a thread.
- **Exact folders.** A subfolder is its own project (`~/repos/b4app/Hub` is not part of `b4app` unless added by hand). Matching uses the canonical form of a path (the coordinator's existing `canonicalDirectory`: tilde expanded, symlinks resolved, no trailing slash). `projectFolders.path` stores that canonical form; `threads.context` is **not** rewritten, because Codex and Claude receive it as the working directory and Claude files its sessions under that exact path. The thread's folder is canonicalised only for the lookup.
- **Manual projects.** On the Mac, Brian can create a project with a name and one or more folders, add a folder to a project, and remove one. A folder belongs to at most one project: adding it to a manual project moves it out of its automatic project, and an automatic project left with no folders is deleted. Removing a folder from a manual project gives it back an automatic project on next use (or immediately, if threads use it; my call).
- **Renaming** works on both devices.
- **B4 threads.** A B4 thread's `context` is a route key, not a folder. A thread on a local B4 connection belongs to the project of its managed server's project directory (found through `connections.localServerId`, created automatically the same way). A thread on a remote B4 connection has no project and appears under "Other" on the Mac and only under "All projects" on the phone.
- **Storage.** The thread carries its project: `threads.projectId` (nullable text), set by the coordinator when it creates the thread and rewritten by the coordinator when a folder moves between projects. The phone never computes membership; it reads the column. Two new synced tables:
  - `projects(id text PK, name text NOT NULL DEFAULT '', manual boolean NOT NULL, createdAt text, updatedAt text)`. Which Mac the folders are on is the row's owner (see "Ownership" below), not a column, so a project backfilled before joining (device `local`) needs no rewrite.
  - `projectFolders(id text PK, projectId text FK → projects ON DELETE CASCADE, path text NOT NULL, createdAt text)`, unique on `path` per device (one Mac per user today, so a plain unique on `path` is enough locally; the hub's key is `(org_id, id)` like every synced table).
- **Migration.** Local migration `0004_organisation.sql` creates the tables and adds `threads.projectId`; the backfill runs in Swift right after it (canonicalisation needs the filesystem): automatic projects from the distinct canonical folders of existing harness threads and from the project paths of local B4 servers, then `projectId` on every thread. Two raw `context` values with one canonical form share one project. The backfill runs with `b4app.replaying` off, so it lands in the change log and syncs like any write.

Commands (coordinator; the mirror answers `project.list` and `project.rename` only, and the rest with `unsupported_capability` naming "the Mac"):

- `project.list` → projects with their folders, each with `displayName` resolved.
- `project.create { name, folders }`, `project.update { projectId, name?, addFolders?, removeFolders? }`, `project.rename { projectId, name }` (the one the phone uses; also on the Mac), `project.delete { projectId }` (manual only; its folders return to automatic projects).
- An event `project.changed { projectId }` so both UIs refresh.

### Attention ordering

Each thread falls into exactly one band, evaluated in this order:

1. **Needs input**: the thread has a runtime request in state `pending` (an approval or a question from the agent), whatever its age.
2. **Working**: the thread's latest turn is not terminal (`submitting`, `running`, `stopping`, `reconciling`; `waiting_for_user` is already covered by band 1).
3. **Unread reply**: the latest turn is terminal (completed, failed, or cancelled; a failure counts as a reply so the error surfaces) and its id is not the thread's read marker.
4. **Quiet**: everything else (nothing running, latest reply read, or no turn yet).

Display order puts unread above working, as the owner listed them: **pinned, then needs input, unread reply, working, quiet**. Pinned threads sit above all bands and are ordered among themselves by the same rules. Within a band, the most recent activity first.

To make this computable identically on both devices from synced data:

- `ConversationThread` gains an additive, optional `activity: ThreadActivity` field on `thread.list` and `thread.read` results: `latestTurnId`, `latestTurnStatus`, `latestTurnOutcome`, `pendingRequests` (count), `lastActivityAt` (conversation activity only: the latest of the thread's `createdAt`, its latest turn's `updatedAt`, and its latest request's `updatedAt`; **not** `threads.updatedAt`, which moves on every pin, rename, archive, and read, so opening or pinning a thread never reshuffles the list, and an edit made on either device orders the same way). The coordinator computes it in SQL in `listThreads`; `MirrorStore` computes it in SQLite from the same synced tables. A shared fixture (`Tests/Fixtures/sync/attention.json`: threads, turns, requests, read markers, and the expected band and order) is run against both stores.
- `WorkspaceProtocol` gains `Attention` with `band(of: ConversationThread) -> AttentionBand` and `ordered(_ threads:) -> [ConversationThread]`, pure functions used by `WorkspaceModel` on both platforms. Nothing about bands is stored or synced.
- The phone needs live band changes: `MirrorStore.apply` already reports touched thread ids for thread rows; it now also reports the `threadId` of every touched `turns` and `runtimeRequests` row, and `MirrorTransport.publish` emits `thread.updated` for those. This also fixes M8a's limitation that turns and requests arriving for an open thread appear only on reopening. On the Mac, `SessionService` already emits turn and request events; `WorkspaceModel` recomputes the band of the affected thread from them.

### Read state

- `threads.readTurnId` (nullable text): the id of the latest terminal turn Brian has seen. It is Brian's, not a device's: reading on the Mac clears the unread state on the phone.
- A thread is marked read when it is open and its latest terminal turn is on screen: on opening the thread, and when a turn finishes while it is open. `WorkspaceModel` sends `thread.markRead { threadId, turnId }`; the coordinator and the mirror write the column only if `turnId` is that thread's latest terminal turn or newer, so a late write from a stale screen cannot mark a newer reply read (the LWW clock settles cross-device races; this guard settles a device racing itself).
- A thread with no finished turn is never unread, so a thread just started, from either device, waits in quiet or working.
- "Mark as unread" (sets `readTurnId` to null) is in the context menu on the Mac and a swipe on the phone (my call; cheap and symmetric).

### The lists

**Phone (iOS `WorkspaceRootView` compact column).** One flat list in attention order. A filter menu at the top replaces the connection picker: "All projects" (default), each project by display name in most-recent-activity order, "Other" when remote B4 threads exist, and "Archived". The connection filter stays available inside the same menu, below the projects (my call; it exists today). Each row shows the status dot (amber needs input, blue unread, green working, grey quiet; the band colours are the LLA palette's warning, accent, success, and muted tokens, my call), title, project name, connection kind, and the reason line (the pending request's kind, "replied 3m ago", the active turn's state). Swipe actions: pin, archive, mark unread. Rename is in the thread header, as today. No band headings (my call; the dots carry it), which a builder can revisit on the owner's word.

**Mac (sidebar).** A "Pinned" section first, then one collapsible section per project, then "Other". Inside each section the same attention order. Sections are ordered by their most urgent thread (the best band, then most recent activity), so a project with a waiting approval rises (my call). Collapsed state is per-device UI state in `@SceneStorage` and never syncs. The connection picker, search, and "Show archived" stay. A project header's context menu has Rename, Add Folder…, and, for a manual project, Delete; a "New Project…" item sits at the bottom of the sidebar. The new-thread sheet keeps its folder picker and shows which project the chosen folder belongs to (or "new project").

### Phone writes

The phone writes these, and only these: `threads.title`, `threads.pinned`, `threads.archived`, `threads.readTurnId`, `projects.name`, and whole `drafts` rows (`threadId`, `text`, `updatedAt`; a draft is shared state with no Mac-only column). A phone edit does not touch `threads.updatedAt` or `projects.updatedAt`. Every other column of a synced table is **Mac-only**.

**Ownership.** A row's owner is the device that most recently uploaded its insert. The hub records it in a new `owner_device_id` on every materialised row, set by insert operations only (today's `device_id` is the last writer of any column). Because `hub leave` followed by `hub join` re-uploads every local row as an insert under the new device id, a rejoined Mac becomes the owner again without any rewrite. The mirror keeps the same value as `ownerDeviceId`; M8c routes relayed commands with it. The hub's write rule is by platform, not by row owner: a `macos` device of the same user may write any column; an `ios` or `cli` device may write only the phone-writable list. That keeps a rejoined Mac from being refused on its own rows during re-upload. (Several Macs per user is out of scope; the rule is revisited with it.)

**A refused change does not stall the queue.** A push batch is applied change by change; a change the rule refuses is not appended or applied, and the response adds `rejected: [{ deviceSeq, code }]` (`column_not_writable`) while `acceptedThrough` still covers it. The client logs it, counts it in Diagnostics, and drops it from its queue. The same per-change rejection is used for a value over `MAX_PAYLOAD_BYTES`, which M8a answered with a 413 that blocked the Mac's queue (an M8a known limitation, fixed here).

- `MirrorTransport` answers `thread.update`, `draft.save`, `thread.markRead`, and `project.rename` by applying the change to the mirror at once (the UI updates immediately) and appending it to a local **outbox** table, `outbox(deviceSeq INTEGER PRIMARY KEY, hlc TEXT, "table" TEXT, rowId TEXT, op TEXT, "column" TEXT, value TEXT)`.
- `MirrorSync` pushes the outbox through the existing `POST /v1/changes` before each pull, in order, removing rows only through the hub's `acceptedThrough`, with the same backoff as pulls. The phone's `deviceSeq` is its own sequence; the hub's `(org_id, device_id, device_seq)` uniqueness already makes a retried push a no-op.
- When the phone pulls its own change back, the clock comparison makes applying it a no-op.
- Offline, the outbox simply grows; Settings → Diagnostics shows its length in the `sync` section ("2 changes waiting to upload").
- **Drafts** become a shared composer: one draft per thread, the last edit wins, and sending clears it everywhere. To make clearing an ordinary last-writer-wins write, `SessionService` clears a draft by setting `text` to `''` instead of deleting the row (the `deleteDraft` at `SessionService.swift:513` becomes an update; the row is still deleted with its thread). The Mac reloads the open thread's draft when a pulled change touches it and the composer is not focused (my call; a focused composer keeps what is being typed and the next keystroke wins).

### Clocks and conflicts

As the M8 design specified, with the details the builder needs:

- **HLC format.** A text value that sorts lexically in clock order: 12 hex digits of milliseconds since the epoch, 4 hex digits of counter, `-`, the device id. Comparison is plain string comparison; equal milliseconds and counters fall back to the device id, the tie-break.
- **Who stamps.** Every change row gets an `hlc`. On the Mac, `WorkspaceDatabase.write` takes the next value from a coordinator-wide `HybridClock` and sets it as the transaction's `b4app.hlc` setting next to `b4app.device_id`; the trigger stores `coalesce(current_setting('b4app.hlc', true), <wall-derived value>)` in a new `changes.hlc` column, so all changes in one transaction share one clock value. The phone's `MirrorStore` stamps outbox rows from its own `HybridClock`. Both clocks advance past every clock they receive in a pull (the HLC receive rule).
- **Which columns merge.** Only the phone-writable columns above, plus `threads.projectId` (written by the Mac only, but rewritten when folders move, so it carries a clock too). Each store keeps a `columnClocks(table, rowId, column, hlc)` table for those columns; an incoming change to one of them is applied only if its `hlc` is greater than the stored one, and then the stored clock advances. An insert of a row carrying those columns counts as one write per column at the insert's clock. All other columns and tables apply exactly as in M8a.
- **The Mac's own writes** update `columnClocks` in the trigger for those columns, so a later pull of an older phone edit cannot overwrite a newer local edit.
- **Hub.** Applies the same rule to its materialised tables with its own `column_clocks`, and clamps any incoming `hlc` more than five minutes ahead of the hub's clock to the hub's clock (keeping the counter and device id), recording the clamp in the log. The change row stores the clamped value so every reader sees the same clock.
- **Wire.** `Change` and `StoredChange` gain `hlc` (string). The hub accepts a change without `hlc` and derives one from `wall` and the device id, so a Mac on the M8a build keeps working until it is rebuilt. The minimum client protocol stays 1; the hub ships first.

### The coordinator pulls

`HubSync` gains a pull loop beside its push loop: long-poll `GET /v1/changes?after=<hubLink.cursor>`, skip changes whose `deviceId` is its own, apply the rest through a new `WorkspaceDatabase.applyRemote(_:)` that runs with `b4app.replaying` on (so nothing is re-recorded or echoed) and honours `columnClocks`, then advance `hubLink.cursor` in the same transaction.

**`applyRemote` is a narrow merge, never a row copy.** The hub holds only filtered copies of the Mac's rows (`SyncFilter` blanks connection targets and secret references and hashes `nativeScope`), so a pulled row must never overwrite a local one. `applyRemote` applies only the phone-writable list: updates to `threads.title`, `pinned`, `archived`, `readTurnId`, and `projects.name` on rows that exist locally, and inserts or updates of `drafts` rows whose thread exists locally. Everything else is skipped, including inserts of any other table, every Mac-only column, and every change from another `macos` device. This makes three cases safe by construction: the Mac's own rows coming back after `hub leave` and `hub join` under its old device id, a snapshot after `resync_required` (its synthetic inserts carry blanked and hashed values), and a pull from zero. After each batch it publishes `thread.updated`, `project.changed`, and the open draft's change as events, so the Mac app refreshes like it does for local writes. `applyRemote` skips a change whose parent row is missing instead of failing the batch (the survey found `replay` throws on a foreign-key violation despite its comment; `applyRemote` fixes that, and `replay` gets the same per-change savepoint).

### Device-aware rows

- The hub gains `GET /v1/devices`: the user's devices with `id`, `name`, `platform`, `lastSeenAt`, `revokedAt`. The mirror stores them in a `devices` table and refreshes it on each pull cycle (at most once a minute; my call).
- The mirror records the origin device of `connections`, `threads`, and `projects` (the `deviceId` of the row's insert) in an `ownerDeviceId` column of its own. The coordinator does not need it.
- The phone shows "on Brian's MacBook Pro" in a connection's detail and a thread's header, read-only. Remote B4 targets stay blanked (my call; the phone never needs the URL, since the Mac does the work in M8c).

### M8a's deferred sync items, landing in M8b

- **Byte-limited pull pages.** `GET /v1/changes` stops a page at 1000 rows or 8 MiB of `value` bytes, whichever comes first, always returning at least one row; `more` is true when it stopped early.
- **`resync_required` for real stale cursors**, with pruning and a snapshot:
  - `b4hub prune --older-than 30d` deletes change rows older than the cutoff (the M8 design's 30-day tombstone window) and records the new horizon per organisation; the Compose file runs it daily from the `hub` container's scheduler (my call: a `prune` loop inside `serve`, every 24 h, configurable with `B4HUB_RETENTION_DAYS`, so there is no second container).
  - A pull with `after` below the horizon answers `resync_required` (410).
  - The client then calls a new `GET /v1/snapshot`, which reads the materialised tables and the column clocks in one repeatable-read transaction and returns them as synthetic insert changes with their clocks plus `next`, the highest `hub_seq` visible to that transaction. The mirror clears its rows (keeping the outbox), applies the snapshot, and continues pulling from `next`. The coordinator gets the same path; its local rows stay, and only the snapshot's phone-writable values go through `applyRemote`'s clock comparison.
- **The mirror schema upgrade path.** `MirrorSchema` gets ordered migrations keyed by `user_version` (v1 is M8a; v2 adds `projects`, `projectFolders`, `devices`, `outbox`, `columnClocks`, `threads.projectId`, `threads.readTurnId`, and `ownerDeviceId`). A database newer than the app knows, or one whose migration fails, is rebuilt: if the outbox is empty, the file is replaced and filled from `GET /v1/snapshot`; if not, the app keeps the old file and shows the error in Diagnostics rather than lose unsent edits.
- **Hub-side defensive scrubbing.** The hub blanks `connections.authReference`, `localServerId`, and `target` on every apply, whatever the client sent, and refuses, change by change, a non-`macos` device's change to any column outside the phone-writable list (see "Phone writes").
- **`FakeHubAPI.me()`** echoes the device name and platform of the enroll request, so tests of `hub status` and the Connect screen see real values.
- **The owner-check inheritance gap.** `serve`'s privileged-connection check (`refuse_privileged_connection`, `Hub/crates/b4hub/src/cli.rs:321`) also refuses a role that inherits superuser, `BYPASSRLS`, or table ownership through membership (`pg_has_role` over the role graph, not only the connected role's own attributes).
- Rate limiting `/v1/enroll` stays in M8d with accounts.

### Hub schema changes (migration `0003_organisation.sql`)

- `changes.hlc text NOT NULL` (backfilled from `wall` and `device_id` for existing rows).
- `owner_device_id uuid` on every materialised table, backfilled from the `device_id` of each row's latest insert in `changes`.
- Materialised `projects`, `project_folders` (named with the Mac's quoted columns like the other tables), `threads."projectId"`, `threads."readTurnId"`.
- `column_clocks(org_id, "table", row_id, "column", hlc)`, PK on all but `hlc`, RLS like every tenant table.
- `org_sync_horizons(org_id PK, horizon bigint)`, RLS.
- The writable-column list lives in `b4hub-core` as data next to the table specs, and the Swift side has the same list in `WorkspaceSync`; the shared fixture `Tests/Fixtures/sync/changes.json` gains a phone title edit, a stale phone edit that loses, a draft clear, and a read marker, decoded by both suites.

### M8b exit

In the Simulator against the Compose hub, with the owner's packaged app joined (it is, since 2026-11-01; the builder rebuilds it from the branch with the dev loop, `./Scripts/package.sh`, quit, `agent-workspace coordinator restart`, reopen, and back to `main` when done). Stopping the hub for the convergence run is harmless to the owner's app, which queues and resumes. Fixture checks come first; the live run is the last task.

1. The Mac sidebar shows Pinned and per-project sections in attention order; the phone shows one list in the same order with the project filter. A fixture turn that opens an approval moves its thread to the top on both within one poll interval; answering it on the Mac moves it to unread, then opening it on the phone makes it quiet on both.
2. Renaming a thread on the phone, pinning one, archiving one, renaming a project, and typing a draft show on the Mac within one poll interval, and the reverse.
3. **Convergence test (fixture, both suites plus one live run):** the phone is taken offline (the hub stopped), both devices rename the same thread and edit the same draft, the Mac's edit later in time; the hub is restarted; both converge on the Mac's values, and with the clocks reversed, on the phone's.
4. A cursor below a pruned horizon resyncs from `/v1/snapshot` without losing an outbox row (fixture).
5. A phone change to a Mac-only column is refused by the hub (fixture), and no hub row contains a secret value, executable path, or pid (the M8a test, extended to the new tables).
6. `cargo test`, `swift test`, and both app builds pass in CI.

## M8c, remote chat

Builds the relay exactly as the M8 design's "The relay" section describes (outbound WebSocket per coordinator, `turn.send`, `turn.interrupt`, `request.respond` routed to the owning Mac, `device_offline` with the last-seen time, first answer wins, the 60 s hold for interrupts and answers, reconnect from a cursor without duplicates), with these additions from the owner's direction:

- **Streaming on the phone.** While the phone has a thread open it subscribes to that thread through the hub; `message.delta` and tool progress are fanned out live and never stored, and the completed item still arrives as a change row. The phone's `MirrorTransport` turns the relayed stream into the same events `WorkspaceModel` already handles on the Mac, so the shared transcript view streams unchanged.
- **The composer on the phone** sends with the shared draft (M8b): sending clears the draft on both devices and posts `turn.send` through the relay. A refusal shows the offline message in place of the send button's spinner and keeps the draft.
- **A new thread from the phone.** The + button opens a sheet: project (most recent first) → folder (only when the project has several) → connection (the owning Mac's conversation-ready Codex, Claude, or local B4 connections) → first message. The phone sends one relayed `thread.create` with the first message to the Mac that owns the project (`projects.deviceId`); the Mac creates the thread in that folder, starts the turn, and the thread arrives through sync while the reply streams. A remote B4 thread cannot be started from the phone in M8c (my call; it needs a route the phone does not have).
- **"Keep the Mac awake"**: the Mac app's first preference.
  - A Settings window (the SwiftUI `Settings` scene) with one toggle, on by default, and help text: "While Agent Workspace is joined to a hub, your Mac stays awake so your phone can reach it. The display can still sleep. A Mac with its lid closed on battery power sleeps anyway."
  - The preference lives in the coordinator, which acts on it: a local, unsynced `settings(key, value)` table, `settings.read` and `settings.update` commands, and a power assertion (`IOPMAssertionCreateWithName` with `kIOPMAssertPreventUserIdleSystemSleep`) held while the toggle is on and the Mac is joined to a hub (my call: not when unjoined, where nothing remote needs it). Released on toggle off, `hub leave`, and coordinator exit. `hub status` and Diagnostics show whether the assertion is held.
- **Ownership.** A thread's owner is the device that most recently uploaded its insert (`ownerDeviceId` from M8b); relayed commands go only there. A project's owner is the Mac whose folders it lists, so a new thread from the phone goes to the project's owner.
- **Exit:** from the Simulator, start a thread in a project, watch the reply stream, answer an approval (and see the Mac's copy resolve once), stop a running turn, and continue an existing Mac thread; the same send with the coordinator stopped is refused with the last-seen time; with the toggle on, `pmset -g assertions` shows the coordinator's assertion while joined.

## M8f, attention on the phone

- **Push registration.** The iOS app registers for remote notifications and sends its token with `POST /v1/devices/self/push-token`; the hub stores it per device.
- **When the hub notifies.** After applying a push batch, the hub checks the materialised rows it just changed: a `runtimeRequests` row entering `pending` makes its thread "needs input"; a `turns` row becoming terminal makes it "unread reply". It notifies the user's iOS devices other than the one that caused the change, once per request or turn id (a `notifications_sent` table makes it idempotent across retries).
- **Content.** Title: the thread's title. Body: a fixed phrase per reason ("Waiting for your approval", "Has a question for you", "Replied", "Turn failed"), never transcript text, command text, or paths (my call; the lock screen is public). The payload carries the thread id; tapping opens the thread through a `b4app://thread/<id>` URL.
- **Swappable sender.** `b4hub` has a `PushSender` trait with two implementations: `apns` (the next slice, with the Developer Program key) and `spool`, which writes each payload as a `.apns` JSON file (with the `Simulator Target Bundle` key) into `B4HUB_PUSH_SPOOL_DIR`. Compose bind-mounts that directory, and `Scripts/sim-push.sh` on the Mac watches it and runs `xcrun simctl push booted <file>`. The iOS code is identical for both.
- **The widget.** A WidgetKit extension target, `B4App-iOSWidget`, small and medium sizes, showing the top three threads in attention order (pinned first) with a status dot each and the project name; tapping a row opens that thread. It reads the mirror directly, read-only, so the mirror moves from the app's Application Support directory into the App Group container `group.com.cacheplane.b4app` (the app moves an existing `mirror.sqlite` there on first launch). The app reloads the widget's timeline after every applied batch, and the push payload sets `content-available` so a notification also lets the app pull and reload. Otherwise the widget refreshes on iOS's own schedule (about every 15 minutes at best), and shows "as of 14:02" when its data is older than five minutes.
- **Exit:** with the Simulator app in the background, a fixture approval on the Mac produces a notification within five seconds of the hub receiving it; tapping it opens the thread; the widget shows the three most urgent threads and updates after the notification.

## Constraints

Everything in the M8 design's constraints, plus:

- `WorkspaceUI` still talks only to `WorkspaceClient`; preferences reach it as coordinator commands, not `UserDefaults` (UI-only state such as a collapsed section may use `@SceneStorage`).
- The attention rules, HLC comparison, and the phone-writable column list each exist once per language and are checked by shared fixtures, not by duplicated hand-written tests.
- `SessionService` remains the only writer of turns, display items, and runtime requests; `applyRemote` never writes those tables from another device (the hub refuses them anyway).
- No `UIApplication` or WidgetKit code in `WorkspaceMirror`; app and extension specifics stay in `Apps/iOS` and the widget target.

## Calls made after the builder check

A reviewer read this document as the engineer who would plan from it. Each of its questions had an answer the owner's direction or the code already implied, so they were settled here; the owner can overrule any of them while reading.

1. The Mac applies only phone-writable values from the hub (`applyRemote` is a narrow merge), so blanked connection columns and hashed scopes from the hub never overwrite local rows, including after a rejoin or a snapshot.
2. A row's owner is the device that last uploaded its insert (`owner_device_id`), so a rejoined Mac owns its rows again; the hub's write rule is by platform (`macos` writes anything, the phone only its list), and `projects` has no device column.
3. Whole `drafts` rows are phone-writable; a refused change is reported per change (`rejected`) and never stalls a queue, which also fixes M8a's blocking 413.
4. `lastActivityAt` is conversation activity only (thread creation, turns, requests), not `threads.updatedAt`, so reading, pinning, or renaming never reorders the list.
5. Project folders store canonical paths; `threads.context` is never rewritten; the backfill groups by canonical form; local B4 threads find their folder through their managed server.
6. The owner's packaged app is already joined, so the live exit is run by the builder with the dev loop after the fixture checks.

## Left to the builder

- The exact SQL of `activity` in Postgres and SQLite, provided the shared attention fixture passes on both.
- How `HybridClock` is shared inside the coordinator (an actor is the obvious shape) and how `WorkspaceDatabase.write` obtains a value without the storage layer importing the coordinator.
- The project filter's control on iOS (a `Menu` in the navigation bar or a toolbar picker), within the LLA visual system.
- The M8c relay's WebSocket framing details and the M8f widget's layout, within the M8 design and LLA.
- Whether the Mac's pull loop shares `HubSync`'s actor or is a sibling actor.
