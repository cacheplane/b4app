# Settings: connections, usage, and B4 projects

Owner-approved direction from a brainstorm on 2026-11-01. The mockups the owner chose are in `docs/superpowers/specs/2026-11-01-settings-connections/`: `connection-card.html` (option B), `b4-form.html` (option B for help, plus the phone layout), `b4-project-card.html` (option A). Open them in a browser; they are drawn in the app's palette and fonts at Mac size.

## Why

When the owner opens Settings → Connections, they want to see at a glance which connections are working and how much of each plan's allowance is left. Today the page answers neither. Status is a text badge, there is no usage at all, and adding or checking a connection gives no sign of progress. The B4 form is four bare fields under a paragraph of instructions, and it asks for a `secret:` reference made in Terminal. A second page, "Local servers", uses "project" for something unrelated to the sidebar's Projects.

The owner's words: "simple and modern indicators: pills, loading-indicator style usage, time remaining; clean and easy to understand". The form "needs to follow Apple's HIG for mac and should have less text and links to show help instead". Every font size, padding, height, and margin must be "grid-aligned and precise and polished", and the page must follow the visual identity.

## Goals

1. Each connection card shows the connection's state as an icon and, for Codex and Claude, the plan's 5-hour and weekly windows as meters with the time to reset. For B4 it shows tokens used today and this week.
2. Add, edit, and check connections from the card and the page. Checks show a spinner and retry before reporting a failure.
3. A B4 connection form that follows the HIG on the Mac (and on the phone, when the phone can manage connections). It has short labels, ⓘ help beside the fields that need it, and a secure field for the API key.
4. The "Local servers" page becomes "B4 projects", with cards in the same family as connection cards and each agent (route) as a row.
5. Everything sits on the theme's spacing grid and type scale, measured, in light and dark, at default and accessibility text sizes.

## Non-goals

- Managing connections or B4 projects from the phone. Its Settings stays read-only (D-060) until M8c or later. The phone shows the cards with status and usage only. The forms are designed for the phone here so the layout is settled, but they do not ship there.
- Usage history, charts, cost in money, or alerts and notifications about limits.
- Buying credits or changing plans.
- Renaming or changing the sidebar's Projects (folders that group threads).
- Removing a connection or a B4 project. The owner asked for add, edit, and check. Removing raises what becomes of the threads bound to a connection, or of the connections made from a project's agents, and that needs its own decision. It is a follow-up (my call, after the builder check).

## Anti-goals (would be failures even if they work)

- A number the runtime did not report. The repo's first rule applies: no mocked or estimated usage. If a runtime has not reported, the card says so; it never draws an empty or guessed meter.
- A new accent colour. Status uses ink, cobalt (in progress), and the existing danger red only.
- A key that is ever visible again after it is saved, or that appears in a log, a JSON result, or UI state after it has been sent.
- A paragraph of instructions on a form.
- A Mac layout change that breaks the smallest window (`DetailMinimumSizeTests`) or the snapshots without a deliberate re-record.

## Constraints

- Visual identity is D-036: ink, white, cobalt (one accent), Hanken Grotesk and JetBrains Mono, with D-060's per-platform scales (`LLATypeScale.mac` / `.phone`, `LLA.Metrics.control` 30 / 44, `row` 0 / 44, `margin` 24 / 16) and D-061's attention to exact metrics.
- Spacing comes only from `LLA.Space` (4, 8, 12, 16, 24, 40). Sizes come only from `LLAFont` roles. A metric not on the grid needs a stated reason in the code.
- Layout rules from `AGENTS.md`: `WorkspaceUI` talks only to `WorkspaceClient`, the UI never touches processes, sockets, files, or secrets directly, and secrets never appear in arguments, JSON results, logs, or UI state.
- Usage data must come from each runtime's real reporting (below), with versions recorded in `docs/compatibility.md`.

## What the runtimes report (checked 2026-11-01)

- **Codex** (codex-cli 0.166.0 app-server). `account/rateLimits/read` returns a snapshot on demand, and `account/rateLimits/updated` pushes changes. A snapshot has `primary` and `secondary` windows of `{ usedPercent, windowDurationMins, resetsAt }`, plus `planType` and `credits`. The schema warns that `ordinaryUsageAllowed`, not the percentages, says whether usage is allowed. Generate the schema with `codex app-server generate-json-schema --out <dir>`.
- **Claude Code** (2.1.282, stream-json). It emits `rate_limit_event` with `rate_limit_info { status: allowed | allowed_warning | rejected, resetsAt?, rateLimitType?, utilization?, unifiedWindows? }` during a turn, whenever a window's rounded percentage or reset time moves. `unifiedWindows.five_hour` and `.seven_day` carry `{ utilization (a 0–1 fraction, can exceed 1), resetsAt (epoch seconds) }`, but the schema marks them `@internal`. The top-level `utilization`, `resetsAt`, and `rateLimitType` describe the window closest to its limit, and are not marked internal. There is no on-demand read, so a card shows the last reading and its age.
- **B4** (0.15.8). It emits a `usage` event per model call (`provider`, `model`, `usage_metadata` with input, output, and total tokens). `B4TurnTranslator` already sums these into `turn.finished.usage`. There is no plan or limit.
- Today the adapters only map limit errors to `allowanceExceeded`; nothing above is stored or shown.

## Decided

### Connections page

- The page title stays "Connections". A "+" button at the top trailing edge (in the page's action slot on the Mac) opens a menu: Codex, Claude, B4….
  - Codex and Claude create the connection and go straight to that runtime's sign-in. The card appears at once with the checking spinner.
  - If a runtime is not installed, its menu item is disabled with a short reason and an install help link. This replaces the "Add a connection" section and its per-runtime install details on the page.
  - B4… opens the B4 form.
- "Re-check runtimes" goes away. The page checks every connection when it opens; each card's menu has Check.

### Connection card (mockup option B)

- One card per connection, full width, in a vertical stack.
- **Header row:**
  - the runtime mark;
  - the name (`bodyStrong`), with the plan and account below it (`small`, muted), e.g. "Pro · brian@…". A B4 card shows its server in mono instead.
  - then the status icon and a "…" menu at the trailing edge.
- **Status is an icon only.** Its words come from the accessibility label and the hover help, never from visible text:
  - **Connected:** an ink circle with a check.
  - **Checking:** a cobalt spinner.
  - **Needs you:** a danger-red circle with "!". Used for sign-in expired, unreachable after retries, or a limit reached.
  - **Not checked or off:** a hollow ghost ring.
- **Codex and Claude meters:** two side by side, "5-hour" and "Weekly".
  - Each has a top line with the label and the percent (tabular figures), then a thin bar, then "Resets in 2h 14m". A reset more than a day away reads as weekday and time, e.g. "Resets Thu 9:00".
  - The bar is ink on `surfaceRaised`. The bar and the percent turn danger red at 90% or more.
  - When Codex reports `ordinaryUsageAllowed == false`, or Claude reports `status == rejected`, the status icon becomes "needs you" whatever the percentages say.
- **Claude adds a line** under its meters: "As of 20 min ago, from the last turn". It ages live.
- **No reading yet:** the meters are replaced by one muted line, "Usage appears after the first turn" (Claude) or "Usage unavailable" (Codex, when the read fails). Never empty bars.
- **B4 cards:** in place of meters, two figures, "Today" and "This week", in tokens (large tabular figures, "tokens" in muted small). Use compact notation ("412k", "2.1M").
- **"…" menu:** Check, Edit, and Sign in (Codex and Claude, when not signed in).
- On the phone the menu is absent (read-only). At accessibility sizes the two meters stack.

### Checking

- A check runs when the Connections page opens, when the user picks Check, and after add or edit. A failed attempt retries twice, after 1 s and then 3 s.
- While checking, the icon is the spinner, and the subtitle reads "Checking…". On a retry it reads "Checking… try 2 of 3".
- After the third failure, the icon is "needs you" and the subtitle gives the reason in a few words, e.g. "Can't reach localhost:3000" or "Sign-in expired".
- Each check also reads Codex's limits. Codex's pushed updates refresh the card at any time.

### B4 connection form (mockup option B)

- **Shape:**
  - On the Mac, a sheet with a title ("Add a B4 connection", or "Edit B4 connection") and a one-line lede.
  - Below that, one grouped section of labelled rows, labels in a leading column.
  - Cancel and Add (or Save) at the bottom trailing edge. Add is the default button and disabled until the form is valid.
- **Fields:**
  - Name (optional; placeholder "Optional", default from the host).
  - Server (mono).
  - Agent, the route key (mono; default `/chat#agent`).
  - API key (optional; a secure field).
- **Help:** an ⓘ beside Agent and API key opens a popover. It has one or two sentences and "Learn more", which links to a help page. There is no footnote or paragraph on the form.
  - The HTTPS rule for remote servers is not prose: it is a validation message under Server, shown only when a non-local `http://` URL is typed.
- **Phone layout** (for when it ships): a form sheet with Cancel and Add in the navigation bar, label above value in 44 pt rows, and the same ⓘ help.
- **Edit** changes only what keeps the connection's identity (my call, after the builder check). Spec 5.2 and D-032 treat another endpoint or route as another account context: old threads would become `identity_changed`.
  - For B4, Edit is the same form, filled in. Name is editable; Server and Agent are shown read-only, with an ⓘ saying that another server or agent is a new connection. The API key row reads "Saved in Keychain" with Replace (or is empty with a secure field when there is none), and never shows the key. A replaced key is a new `secret:` reference; the old secret is deleted from the store once the connection no longer uses it.
  - For Codex and Claude, Edit is a small sheet with the name only.
  - This needs a new `connection.update` command (`connectionId`, optional `label`, optional `authReference`), a mutation that bumps `profileRevision` and publishes `connection.changed`.
- **The key:** the form sends it with the existing `credential.add` request over the 0600 socket (D-022's path, the one the CLI uses), receives the `secret:` reference, and attaches the connection with that reference.
  - The secure field's value is cleared as soon as it is sent, and is never stored in the model or logged.
  - This revises D-022's "the GUI form collects the reference, never the value". Record the revision as a new decision.

### B4 projects page (renamed from "Local servers"; mockup option A)

- **Names:**
  - The Settings entry and page title are "B4 projects".
  - The add button is "Attach B4 project…".
  - The sidebar's Projects keep their name.
- **Card header:**
  - the B4 mark and the project name;
  - the status icon: running = connected, starting = spinner, stopped = hollow ring, failed = "needs you";
  - an icon button to start or stop;
  - a "…" menu with Restart, Inspect agents, and Show log.
- **Below the header:**
  - the folder (mono, muted, `~` abbreviated);
  - a pill for the mode (Dev or Source);
  - a pill for the port while running, or the state word ("Starting…", "Stopped").
- **Agents:** each route is a row with its key in mono. A trailing Connect button, or a quiet "✓ Connected" once a connection uses it.
- **Failure:** a failed start shows "needs you" and one line saying why, with Show log beside it.
- **The log:** opens in its own sheet, not on the card.
- **Attach B4 project…** opens a sheet in the B4 form's style. It keeps every field the current form has (my call, after the builder check: dropping one would make it CLI-only):
  - Folder: a path field with Choose…, and an ⓘ saying that attaching runs the project's config and routes with Node.
  - Name: optional, defaults to the folder's name.
  - Mode: Dev or Source, as a segmented control, with an ⓘ about hot reload replacing the runtime mid-turn.
  - Port: optional, with an ⓘ saying it is allocated once when empty.
  - Env file: optional, with an ⓘ saying it defaults to `<project>/.env` and is passed to the server, never read into the app.
  - The trust warning stays visible, because it is a safety decision rather than help: one line above the buttons, "Attaching runs this project's code. Attach only projects you trust."

### Grid and metrics (from the mockups)

| | Mac | Phone |
|---|---|---|
| Card | padding 16, corner 12, `surface` fill, 1 px `rule` border, 12 between cards | same, page margin 16 |
| Header | mark 24, gaps 8, name `bodyStrong`, subtitle `small` muted | name at the phone's 17 pt body |
| Icon buttons ("…", start/stop) | `LLA.Metrics.control` (30) | 44 pt target |
| Status icon | 16 pt, scales with `@ScaledMetric` | same |
| Meters | two columns, 16 apart; label/percent `caption`, 4 to the bar; bar 4 tall, corner 2; reset line `caption` muted, 4 below the bar; 12 above the meters | stack at accessibility sizes |
| Form rows | label column 96, gap 12, control height 30, row height 48, group corner 12 | 44 pt rows, label above value |
| Sheet | 24 margins, Cancel/Add 30 tall, 24 above them | system form sheet |

The builder may adjust a value to match an existing `LLAFont` role or `LLA.Space` step, but not to a value off the grid.

## Left to the builder

- **Where usage lives.** The likely shape:
  - a coordinator-owned latest snapshot per connection for Codex and Claude (with the time observed);
  - stored per-turn token counts for B4, summed by local day and by week (Monday start unless the builder finds a reason otherwise);
  - a protocol method or a field on the connection that the card reads.
  - Whether usage syncs to the phone through the hub, so the phone's cards can show it, is part of this: either sync it, or show "Usage on your Mac" on the phone.
- **Claude's windows.** Whether to read Claude's `@internal` `unifiedWindows` (with the top-level fields as the fallback when it is absent), and how to record that risk in `docs/compatibility.md`.
- **Fixtures.** `fake-codex.py` and `fake-claude.py` gain rate-limit messages; live checks stay behind `B4APP_LIVE_*`.
- **Retries.** How the check retry is driven (coordinator or client), as long as the card can show which attempt is running.
- **Help pages.** The help page each "Learn more" opens (a docs page in the repo, rendered or linked).
- **The "+" placement on the Mac.** The page's existing action slot or a toolbar item.
- **Decisions and docs.** New D-numbers for this design, the D-022 revision, and the rename; `docs/verification.md` entries with measured screenshots (Mac light and dark, phone default and AX3).

## Calls made while planning (not the owner's)

The owner approved the direction above and asked for it to be built without further questions. These were settled on the owner's behalf, the safe way. Each can be revisited.

- **No Remove for connections or B4 projects** in this change (see Non-goals).
- **Edit keeps identity.** Name and API key only; Server and Agent are read-only (see the B4 form).
- **Attach B4 project keeps Name, Port, and Env file.**
- **Usage stays on the Mac.** Connections reach the phone through the hub's fixed column list (`SyncFilter.connectionColumns`, the hub's `TableSpec`, and `Tests/Fixtures/sync/changes.json`). Sending usage there would change the Rust hub and the shared contract while the M8c relay branch is also changing sync. The phone's cards show status only, with one muted line, "Usage shows on your Mac". A follow-up can sync it.
- **Usage storage is local-only:** a new migration, `0006_usage.sql`, so it cannot collide with the relay branch's `0005_relay.sql`, whichever merges first. Its tables are not in the change log.
- **Claude windows:** read `unifiedWindows` when present, and fall back to the top-level `utilization` and `resetsAt` (placed by `rateLimitType`) when it is absent. Record the `@internal` risk in `docs/compatibility.md`.
- **Retries** are driven by the coordinator inside `connection.inspect`, which publishes each attempt on `connection.changed` (`attempt`, `of`), so the card can show "try 2 of 3".
- **Help:** each "Learn more" opens a section of one help page in the repo, `docs/help/connections.md`, at its GitHub URL.
- **"+" on the Mac** uses the page's existing action slot (`SettingsPageAction`), as a menu.
