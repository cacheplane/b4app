# Start a thread from a blank composer

Date: 2026-11-03. Owner: Brian Love. Status: draft for the owner's review. Calls marked *(my call)* were made by the designer and can be reversed cheaply; everything else is the owner's.

## Intent

Starting a thread today means a dialog: `NewThreadSheet` on the Mac, `PhoneNewThreadSheet` on the iPhone, each asking for a connection and a folder (or a B4 route) before anything can be typed, and creating an empty thread on Create. Most chat apps start from a blank composer instead: you start typing, and where the message goes (project, runtime, model, permissions) sits quietly under the field, already set to something sensible. The owner wants B4 to work that way. The composer *is* the new thread; there is no "New thread" step when no thread is open, and from inside a thread one click (or ⌘N) puts the cursor in a blank composer.

## Goals

- With no thread open, the main pane is the new-thread composer, focused, ready for typing. No dialog anywhere.
- "New thread" (sidebar row, ⌘N, the iPhone's bottom field, the continuity banner's button) navigates to that composer and focuses the field.
- The composer can be opened with a project id, which preselects that project.
- Under the field: a project · folder picker on the left; a permissions picker and one runtime · model picker on the right.
- The thread does not exist until Send. Send creates it, starts the first turn, and opens it.
- Inside an existing thread, the permissions and model pickers stay under the composer and change what the *next* turn uses.
- A thread gets every folder of its project as context, starting in one of them.
- The same start on the iPhone (and iPad), plus a cleanup of the iPhone's thread list.

## Non-goals

- Attachments and voice input. The + and mic buttons are not drawn until those features exist (repo rule: never show a mocked capability as working). The layout leaves room for them: D-061 already puts attach at the leading end of the composer's tool row, and the mic goes beside it.
- Changing a thread's runtime, connection, project, or starting folder after it starts.
- A shared, runtime-neutral permission vocabulary.

## Anti-goals

- Empty threads piling up from opened-and-abandoned composers.
- Any picker that implies a capability the runtime does not have (a model list the runtime ignores, a permission it does not enforce).
- Chips, icons, colour, or badges in the picker row. The LLA rules hold (`2026-10-31-lla-visual-system-design.md`): muted text and a small chevron; the accent only for focus and the caret.

## The Mac

Approved mockup: `.superpowers/brainstorm/*/content/composer-row-v2.html`, option B (gitignored scratch; this section is the reference).

**Empty pane.** When `selectedThreadId` is nil and at least one connection is conversation-ready, `ThreadsView` shows a headline (display type) above the composer, the pair centred vertically in the reading column (720 pt max). The sidebar's "New thread" row shows selected while this screen is up. The field is focused on appear. When no connection is ready, today's empty state with "Add connection" stays.

**Composer.** Today's `ComposerView` field (D-061 shapes, `surface` fill, `rule` border, ink send circle, disabled send recedes). No + or mic yet. The placeholder names the runtime ("Message Claude Code"), as the thread composer already does.

**Row under the field**, 8 pt below it, small (13 pt) muted text, each item a menu button with a chevron:

- Left: **project · folder**. A project with one folder reads as its name; with several, `name · folder` *(my call: folder shown by its last path component)*. The menu lists each project as a group header with its folders under it; choosing a folder chooses both. A one-folder project is a single item. Last item: "Choose folder…" (the Mac's folder panel), which starts a new project from that folder, as the sheet's "Starts a new project from this folder" does today.
- Right: **permissions**, then **runtime · model** (e.g. the Anthropic mark ghosted, "Claude Code · Sonnet"). The runtime · model menu groups models under each conversation-ready connection: Claude Code connections, then Codex, then the B4 agents of the selected project (a B4 agent is a single item, no model). Two connections of one runtime are two groups, each headed by the connection's label.
- Choosing a B4 agent hides the permissions picker; the agent's route decides.

**From inside a thread.** The sidebar row and ⌘N clear the selection, show this screen, and focus the field; the open thread's draft is saved as today.

## Permissions, in each runtime's own words

The permissions menu shows the options of the runtime chosen in the runtime · model picker, labelled as that runtime's own client labels them *(my call: which options and the exact labels)*. Each runtime's menu starts with **As configured**, the default: it passes nothing, so the user's own Codex or Claude configuration decides, as D-012 has it today. Any other entry overrides that configuration for the thread. This amends D-012 (a new decision, numbered when the PR opens): the app now passes a policy, but only when the user picks one. Under "As configured" the Claude adapter stops passing `--permission-mode default`, so Claude's own settings apply too.

- **Claude Code**: Ask permissions (`default`), Accept edits (`acceptEdits`), Plan mode (`plan`), Bypass permissions (`bypassPermissions`). Maps to `--permission-mode`.
- **Codex**: Read only, Auto, Full access — Codex's `/approvals` presets, each setting an approval policy and a sandbox together (read-only + on-request; workspace-write + on-request; danger-full-access + never). Maps to `ThreadPolicy` today and its per-turn equivalent.

Switching runtime before the first send resets permissions to "As configured".

The phone offers the same menus as the Mac, the most permissive modes included. A mid-thread change from the phone is a synced field on the thread, applied by the Mac on the next turn; it does not go through the relay.

## No directory lock

The one-writing-run-per-directory lock (D-033, spec 10.1.5) is removed. With every project folder attached, a per-folder lock no longer covers what a thread can write, and neither the Claude nor the Codex app has one: two threads may run in the same folder at once. This amends D-033 and departs from spec 10.1.5 (a new decision, numbered when the PR opens). `assertFolderFree` (`SessionService`), the `directory_locked` refusal, its entry in `RelayExecutor.blockingReasons`, its remediation copy in `Remediation.swift`, and their tests go away. Spec 10.1.5 is the owner's document and is not edited; the decision records the departure.

## Projects and folders

A thread gets all of its project's folders. One is the starting folder: the runtime's working directory, where it runs commands and git, and whose `AGENTS.md` / `CLAUDE.md` it reads. The others are attached as additional directories: Claude Code's `--add-dir` (`ClaudeStream.addDirectories`, already plumbed, unused) and Codex's additional writable roots.

D-048's membership rule stands *(my call)*: a thread's project is still derived from its working directory, which is now its starting folder, and the picker only offers a project's own folders, so the derived project is always the one picked. No project id is stored on the thread, and when a folder moves between projects (D-048's moves), its threads follow it. What is new, to be recorded as a decision amending D-048 (numbered when the PR opens): each Codex or Claude turn attaches the other folders of the thread's current project as additional directories, read when the turn starts, so a folder added to the project later reaches every thread of that project, older threads included, on its next turn *(my call)*.

"Choose folder…" *(my calls)*: the project is resolved on Send, never when the folder is picked, so an abandoned composer leaves no automatic project behind. A folder that is exactly one of a project's folders starts in that project. Any other folder, a subfolder of a project's folder included, gets an automatic project of its own on Send, as D-048 does today. Until Send, the project picker shows the folder's name.

**Remote B4** *(my call)*: remote B4 connections have no project. The runtime · model menu lists them in a last group, "Remote B4", on the Mac only. Choosing one sets the project picker to "No project" (locked) and hides permissions. This keeps the one way the Mac has today to start a remote B4 thread.

## Defaults

The pickers open on the last choices *(my call: per device, not synced)*:

- Project: the one the last thread was started in; a project id passed in overrides it.
- Folder: the last starting folder chosen in that project; the project's first folder when there is no history.
- Runtime · model and permissions: the last ones used in that project; otherwise the last ones used anywhere; otherwise the first ready connection, its default model, and "As configured".

## Inside a thread

Under the thread's composer, the same row: project · folder shown but not interactive *(my call: muted, no chevron)*; permissions and model live, the model menu limited to the thread's connection. A change applies from the next turn and is stored on the thread, so the next device to open it shows the same choice. B4 threads show neither picker. A thread whose runtime cannot change model or permissions mid-session shows the picker disabled with the reason in its help text, never a picker that does nothing.

## The iPhone

Approved mockup: `.superpowers/brainstorm/*/content/phone-list.html`, option A.

**Thread list.**
- Header: the profile avatar leading (opens today's profile menu, which leaves the bottom footer); trailing, the existing filter menu and a new search button. The compose button leaves the header.
- Search: the button reveals the list's existing search field at the top, as in Mail *(my call)*.
- Bottom: a single "New thread" field (capsule, `surface`, the disabled send circle) replaces the profile footer and the bottom search bar. Tapping it pushes the new-thread screen. It does not accept text in place.
- "Connect your Mac" still takes the list's place while the account has no Mac.

**New-thread screen.** Pushed onto the detail column, titled "New thread", the headline above, the composer at the bottom with the keyboard up, the picker row between the field and the keyboard. On the phone the runtime · model picker shortens to the runtime mark and the model name; its menu still names runtimes. The project menu lists `startProjects` (projects whose owning Mac is known); the runtime menu lists `startConnections(for:)` (that Mac's ready Codex and Claude connections, and local B4 agents of that project, never remote B4). When the owning Mac is offline or has left the hub, the screen shows `startNotice` and Send is off.

**iPad** (regular width) behaves like the Mac: no thread selected means the detail is the blank composer.

## Sending

Send creates the thread and starts its first turn in one command, the shape the relay's `thread.start` already has (thread id minted by the client, project, connection, folder, text). The Mac uses it too *(my call)*, extended with model and permissions. On the Mac the project id is optional: a folder from "Choose folder…", or a remote B4 connection, comes with none, and the coordinator resolves the project as above. The phone always sends both, and the relay's `folder_outside_project` check stays. `thread.create` without a first message is no longer called by the apps. The thread is titled from the first message *(my call: its first line, trimmed to the existing title length)*; rename works as today.

If the send fails before the thread exists, the composer keeps the text and shows the error as the thread composer does. An unsent draft on the new-thread screen survives navigation and relaunch until sent or cleared *(my call: one draft per device)*.

## What goes away

`NewThreadSheet`, `PhoneNewThreadSheet`, `WorkspaceModel.showNewThread` and its sheet, and the empty state's "New thread" button. Accessibility ids `new-thread`, `new-thread-toolbar`, and `create-thread` are retired or reassigned; tests that use them move to the new screen.

## Constraints

- `WorkspaceUI` talks only to `WorkspaceClient`; the UI never touches processes or files (the folder panel returns a path, the coordinator decides the project).
- `SessionService` stays the only writer of threads and turns.
- Model and permission changes must reach the runtime for real or be refused with `WorkspaceError(.unsupportedCapability)`. `modelSelection` is `unverified` on both adapters today; the builder verifies it (fixture tests with the fake runtimes; live checks opt-in) and records versions in `docs/compatibility.md`.
- Changes to relayed methods update `Tests/Fixtures/sync/relay.json` and both suites.
- `swift format lint --strict`, `swift test`, both `xcodebuild` schemes.

## Left to the builder

- The headline's wording (the mockups' "What should we work on?" is a stand-in).
- Where model lists come from per runtime (Codex's app-server listing; Claude Code's aliases), and how they are cached.
- How a live Claude session takes a new model or permission mode (its control messages, or a restart with `--resume`), and how Codex takes them per turn.
- Storage for a thread's starting folder, model, and permissions, and the migration.
- Spacing inside the row, the menus' exact layout, and the phone row's fit at the largest text sizes.
- The order of work, provided each merged step leaves both apps usable.
