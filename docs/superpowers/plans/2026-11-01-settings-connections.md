# Settings: connections, usage, and B4 projects — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connection cards with icon status, real plan usage (Codex, Claude) and token totals (B4), checks that retry, HIG forms for adding and editing, and a "B4 projects" page with agent rows.

**Architecture:** Adapters report usage as a new `usage.changed` adapter event (Claude from `rate_limit_event`, Codex from `account/rateLimits/updated`) and Codex also on demand. `SessionService` stores the latest reading per connection and B4 token counts per turn in two local-only tables, and serves them through `usage.read`. The SwiftUI pages read `WorkspaceModel.usage`, rebuilt from `usage.read` and patched by events.

**Tech Stack:** Swift 6, SwiftUI (macOS 26 / iOS 26), swift-testing, PostgreSQL via `WorkspaceStorage`, Python fixture runtimes.

**Spec:** `docs/superpowers/specs/2026-11-01-settings-connections-design.md` (mockups in `docs/superpowers/specs/2026-11-01-settings-connections/`).

## Global Constraints

- D-036 identity: ink, white, cobalt (the one accent), Hanken Grotesk and JetBrains Mono; danger red only for "needs you" and a meter at ≥ 90%.
- Spacing only from `LLA.Space` (4, 8, 12, 16, 24, 40); type only from `LLAFont` roles; `LLA.Metrics.control` 30 (Mac) / 44 (phone), `margin` 24 / 16.
- `WorkspaceProtocol` and `WorkspaceClient` stay Foundation-only; `WorkspaceUI` talks only to `WorkspaceClient`.
- Secrets never appear in arguments, JSON results, logs, or UI state after they are sent; the form's key goes through `credential.add` and is cleared at once.
- No mocked usage: a card without a reading says so; it never draws a guessed meter.
- New migration is `0006_usage.sql` (the relay branch owns `0005`). Usage tables get no change-log trigger.
- Keep edits to `Commands.swift`, `Events.swift`, `SessionService.swift`, `Router.swift`, `WorkspaceModel.swift`, `SettingsView.swift` small (the M8c relay branch edits them too); new code goes in new files.
- Phone Settings stays read-only (`WorkspaceDevice.managesWorkspace`).
- `swift format lint --strict --recursive Sources Tests Apps Package.swift` clean before each commit.

## Review Focus

1. A Claude `rate_limit_event` without `unifiedWindows` (older CLI, or the internal field removed): the card must fall back to the top-level `utilization`/`resetsAt` placed by `rateLimitType`, and show nothing for the other window rather than 0%. Test in Task 4.
2. `utilization` above 1 (Claude allows it past a cap) or `usedPercent` above 100: the bar clamps to full and the label shows the real number. Test in Task 7.
3. A reset time in the past (stale reading): "Resets in" must not go negative; show "Reset" with no time. Test in Task 7.
4. A B4 turn that finishes with no `usage` (cancelled early, or an older server): nothing is recorded and totals are unchanged; a turn re-finished after reconcile is counted once (keyed by turn id). Test in Task 5.
5. Replacing a B4 key while a thread on that connection is open: the next turn uses the new key (the cached adapter is evicted) and the old secret is removed only if no other connection uses it. Test in Task 5.

---

### Task 1: Protocol types, commands, and the usage event

**Files:**
- Create: `Sources/WorkspaceProtocol/Usage.swift`
- Modify: `Sources/WorkspaceProtocol/Commands.swift` (two `Method` cases and `isMutation`)
- Modify: `Sources/WorkspaceProtocol/Events.swift` (one `AdapterEventKind` case; two defaulted parameters on `connectionChanged`)
- Test: `Tests/WorkspaceProtocolTests/UsageTests.swift`

**Interfaces:**
- Produces:
  - `struct UsageWindow: Codable, Sendable, Equatable { var usedPercent: Double; var windowMinutes: Int?; var resetsAt: String? }` (ISO-8601 UTC).
  - `struct UsageReading: Codable, Sendable, Equatable { var fiveHour: UsageWindow?; var weekly: UsageWindow?; var blocked: Bool; var planType: String?; var observedAt: String }`.
  - `struct TokenTotals: Codable, Sendable, Equatable { var today: Int; var week: Int }`.
  - `struct ConnectionUsage: Codable, Sendable, Equatable, Identifiable { var connectionId: String; var reading: UsageReading?; var tokens: TokenTotals?; var id: String { connectionId } }`.
  - `enum UsageRead: WorkspaceCommand` (`usage.read`, params `EmptyParams`, result `{ usage: [ConnectionUsage] }`), not a mutation.
  - `enum ConnectionUpdate: WorkspaceCommand` (`connection.update`, params `{ connectionId: String; label: String?; authReference: String?; clearAuth: Bool? }`, result `ConnectionAdd.Result`), a mutation.
  - `AdapterEventKind.usageChanged = "usage.changed"`; `AdapterEvent.usageChanged(connectionId: String, reading: UsageReading, adapterGeneration: Int = 0) throws -> AdapterEvent` with payload `["reading": <encoded>]`.
  - `AdapterEvent.connectionChanged(..., attempt: Int? = nil, attempts: Int? = nil)`: when non-nil, payload gains `"attempt"` and `"attempts"` numbers.

- [ ] **Step 1: Write the failing tests.** `usageReadingRoundTrips` (encode then decode equals), `newMethodsAreAllowlistedWithTheRightMutability` (`Method(rawValue: "usage.read")?.isMutation == false`, `Method(rawValue: "connection.update")?.isMutation == true`), `connectionChangedCarriesTheAttempt` (`payload["attempt"]?.numberValue == 2`, `payload["attempts"]?.numberValue == 3`; absent when nil).
- [ ] **Step 2: Run** `swift test --filter UsageTests` and expect a compile failure.
- [ ] **Step 3: Implement** the types above, in `Usage.swift` beside the two command enums.
- [ ] **Step 4: Run** `swift test --filter WorkspaceProtocolTests` and expect PASS.
- [ ] **Step 5: Commit** `feat(protocol): usage readings, usage.read, connection.update`.

### Task 2: Usage storage

**Files:**
- Create: `Sources/WorkspaceStorage/SQL/0006_usage.sql`, `Sources/WorkspaceStorage/Usage.swift`
- Test: `Tests/WorkspaceStorageTests/UsageStoreTests.swift`

**Interfaces:**
- Produces, on `WorkspaceDatabase`:
  - `func saveUsage(connectionId: String, reading: UsageReading) throws`, which replaces the connection's reading;
  - `func usageReadings() throws -> [String: UsageReading]`;
  - `func recordTokens(turnId: String, connectionId: String, total: Int, at: String) throws`, which is idempotent per `turnId`;
  - `func tokenTotals(connectionId: String, since: String) throws -> Int`.
- SQL:
  - `"usageReadings" ("connectionId" text PRIMARY KEY REFERENCES "connections"("id") ON DELETE CASCADE, "reading" text NOT NULL, "observedAt" text NOT NULL)`;
  - `"tokenUsage" ("turnId" text PRIMARY KEY, "connectionId" text NOT NULL REFERENCES "connections"("id") ON DELETE CASCADE, "recordedAt" text NOT NULL, "totalTokens" bigint NOT NULL)` with an index on `("connectionId", "recordedAt")`.
  - No triggers.

- [ ] **Step 1: Write the failing tests.**
  - `usageReadingIsReplacedPerConnection`: save twice; `usageReadings()[id] == second`.
  - `tokensSumSinceABoundaryAndCountATurnOnce`: record a turn of 100 tokens at 09:00 and one of 50 at 11:00; record the 11:00 turn again with 50. Then `tokenTotals(since: 10:00) == 50`, and `tokenTotals(since: 08:00) == 150`.
  - `usageTablesAreNotInTheChangeLog`: after writes, `changes(after: 0)` has no row whose table is `usageReadings` or `tokenUsage`.
- [ ] **Step 2: Run** `swift test --filter UsageStoreTests` and expect FAIL.
- [ ] **Step 3: Implement** the migration and the four methods, using `read`/`write` and `Rows.quote` as `ProjectStore` does. Use `INSERT … ON CONFLICT DO NOTHING` for tokens and `ON CONFLICT DO UPDATE` for readings.
- [ ] **Step 4: Run** `swift test --filter WorkspaceStorageTests` and expect PASS (the migrations test sees `0006_usage`).
- [ ] **Step 5: Commit** `feat(storage): local usage readings and B4 token counts (0006)`.

### Task 3: Codex usage

**Files:**
- Create: `Sources/CodexAdapter/CodexUsage.swift`
- Modify: `Sources/CodexAdapter/CodexAdapter.swift` (`readUsage()`), `Sources/CodexAdapter/CodexEvents.swift` (`account/rateLimits/updated`)
- Modify: `Sources/WorkspaceProtocol/Adapter.swift` (add `protocol UsageReporting: Sendable { func readUsage() async throws -> UsageReading? }`)
- Modify: `Tests/CodexAdapterTests/Fixtures/fake-codex.py` (answer `account/rateLimits/read`; after each completed turn push `account/rateLimits/updated`)
- Test: `Tests/CodexAdapterTests/CodexUsageTests.swift`

**Interfaces:**
- Consumes: `UsageReading`, `UsageWindow`, `AdapterEvent.usageChanged` (Task 1).
- Produces:
  - `enum CodexUsage { static func reading(from snapshot: JSONValue, observedAt: String) -> UsageReading? }`.
    - The window with `windowDurationMins` ≤ 300 is `fiveHour`; the one with ≥ 10080 is `weekly`. A window without a duration is placed by role: `primary` is `fiveHour` and `secondary` is `weekly`.
    - `resetsAt` (epoch seconds) becomes ISO.
    - `blocked = (ordinaryUsageAllowed == false) || rateLimitReachedType != nil`.
    - Returns nil when neither window is present.
  - `CodexAdapter: UsageReporting`, which calls `account/rateLimits/read` and passes the snapshot to `CodexUsage.reading`.
- Fixture snapshot (pin these values): `primary { usedPercent: 62, windowDurationMins: 300, resetsAt: now+8040 }`, `secondary { usedPercent: 31, windowDurationMins: 10080, resetsAt: now+300000 }`, `planType: "pro"`, `ordinaryUsageAllowed: true`.

- [ ] **Step 1: Write the failing tests.**
  - `mapsPrimaryAndSecondaryWindows`, using the pinned values: `fiveHour.usedPercent == 62`, `weekly.windowMinutes == 10080`, `planType == "pro"`, `blocked == false`.
  - `placesWindowsByDuration` (swapped roles).
  - `blockedWhenOrdinaryUsageIsNotAllowed`.
  - `noWindowsIsNoReading`.
  - `readUsageAsksTheAppServer`: against `fake-codex.py`, `readUsage()?.fiveHour?.usedPercent == 62`.
  - `rateLimitsUpdatedBecomesAUsageEvent`: the translator maps the notification to `.usageChanged`.
- [ ] **Step 2: Run** `swift test --filter CodexUsageTests` and expect FAIL.
- [ ] **Step 3: Implement** the parsing, `readUsage()`, the notification case, and the fixture responses.
- [ ] **Step 4: Run** `swift test --filter CodexAdapterTests` and expect PASS.
- [ ] **Step 5: Commit** `feat(codex): read and follow plan rate limits`.

### Task 4: Claude usage

**Files:**
- Create: `Sources/ClaudeAdapter/ClaudeUsage.swift`
- Modify: `Sources/ClaudeAdapter/ClaudeStream.swift` (frame `.rateLimit(JSONValue)` for `type == "rate_limit_event"`), `Sources/ClaudeAdapter/ClaudeEvents.swift` (translate it)
- Modify: `Tests/ClaudeAdapterTests/Fixtures/fake-claude.py` (emit one `rate_limit_event` per turn before `result`)
- Test: `Tests/ClaudeAdapterTests/ClaudeUsageTests.swift`

**Interfaces:**
- Produces: `enum ClaudeUsage { static func reading(from info: JSONValue, observedAt: String) -> UsageReading? }`.
  - **With `unifiedWindows`:**
    - `five_hour` maps to `fiveHour` with `windowMinutes` 300; `seven_day` maps to `weekly` with `windowMinutes` 10080.
    - `usedPercent = utilization × 100`, with no clamp.
    - `resetsAt` comes from epoch seconds.
  - **Without it:** the top-level `utilization` and `resetsAt` go into the window that `rateLimitType` names (`five_hour` or `seven_day*`). The other window is nil.
  - `blocked = status == "rejected"`.
  - Returns nil when no window can be placed (for example `rateLimitType == "overage"` with no `unifiedWindows`).
- Fixture event (pin these values): `{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","rateLimitType":"five_hour","utilization":0.91,"resetsAt":<now+2280>,"unifiedWindows":{"five_hour":{"utilization":0.91,"resetsAt":<now+2280>},"seven_day":{"utilization":0.48,"resetsAt":<now+400000>}}},"uuid":"…","session_id":"…"}`.

- [ ] **Step 1: Write the failing tests.**
  - `mapsUnifiedWindows`: `fiveHour.usedPercent == 91`, `weekly.usedPercent == 48`.
  - `fallsBackToTheLimitingWindow`: no `unifiedWindows`, `rateLimitType "seven_day"`, `utilization 0.5`. Then `weekly.usedPercent == 50` and `fiveHour == nil`.
  - `keepsUtilizationPastTheCap`: 1.2 gives 120.
  - `rejectedIsBlocked`.
  - `overageAloneIsNoReading`.
  - `aTurnEmitsUsageChanged`: against `fake-claude.py`, the adapter's events include `.usageChanged` with `fiveHour.usedPercent == 91`.
- [ ] **Step 2: Run** `swift test --filter ClaudeUsageTests` and expect FAIL.
- [ ] **Step 3: Implement** the frame, the translation, and the fixture.
- [ ] **Step 4: Run** `swift test --filter ClaudeAdapterTests` and expect PASS.
- [ ] **Step 5: Commit** `feat(claude): follow plan windows from rate_limit_event`.

### Task 5: Coordinator: store usage, `usage.read`, retries, `connection.update`

**Files:**
- Create: `Sources/Coordinator/UsageService.swift` (an extension of `SessionService` holding the usage, retry, and update logic)
- Modify:
  - `Sources/Coordinator/SessionService.swift`: in `project(_:)`, route `.usageChanged`, and route `.turnFinished` with a `usage` payload for B4; in `connectionInspect`, call the retry wrapper; add a stored `retryDelays: [Duration]`, default `[.seconds(1), .seconds(3)]`, settable from `CoordinatorOptions`;
  - `Sources/Coordinator/Router.swift`: two cases;
  - `Sources/Coordinator/Coordinator.swift`: plumb `retryDelays` through options.
- Test: `Tests/CoordinatorTests/UsageTests.swift`

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces, on `SessionService`:
  - `func usageRead() throws -> UsageRead.Result`: one entry per connection.
    - Codex and Claude get `reading` from `usageReadings()`.
    - B4 gets `tokens`: today since local midnight, week since local Monday 00:00, both converted to UTC ISO.
  - `func connectionUpdate(_ params: ConnectionUpdate.Params) async throws -> ConnectionAdd.Result`.
- Behaviour:
  - **Retries.** `connectionInspect` tries up to `1 + retryDelays.count` times when the inspection status is `.offline` or `.error`, and never on `.incompatible` or an auth state.
    - Before each try it publishes `connectionChanged(status: .connecting, …, message: "Checking…", attempt: n, attempts: total)`.
    - The final inspection is stored as today.
    - After a `.ready` inspection with `authStatus == .authenticated`, it reads usage from a `UsageReporting` adapter, saves it, and publishes `usage.changed`. A failed usage read is ignored; usage stays as it was.
  - **`usage.changed` from an adapter** is saved, then republished as-is.
  - **B4 `turn.finished`** with `payload.usage.usage_metadata.total_tokens` calls `recordTokens(turnId:…)`.
  - **`connectionUpdate`:**
    - A trimmed non-empty `label` sets the label.
    - `authReference` (only for `.b4`) must resolve in the secret store, or it is refused with `notFound`. It sets the reference.
    - `clearAuth == true` removes the reference.
    - Either auth change evicts the cached adapter (dispose it, cancel its pump) and removes the replaced secret when no other connection references it.
    - Any change bumps `profileRevision` and publishes `connection.changed`.
    - Every other field is untouched. A `connectionId` that doesn't exist is refused with `notFound`.

- [ ] **Step 1: Write the failing tests** (with `Harness.start()` and `retryDelays: [.zero, .zero]`).
  - `codexCheckStoresUsage`: `usage.read` gives the Codex entry with `reading.fiveHour.usedPercent == 62`.
  - `claudeTurnStoresUsage`: after one turn, the Claude entry has `fiveHour.usedPercent == 91`.
  - `b4TurnsSumIntoTodayAndWeek`: two turns against `FakeB4` (15 and 7 tokens) give `today == 22` and `week == 22`; reconciling the finished turn leaves 22.
  - `unreachableB4RetriesThenFails`: a B4 connection on a closed port publishes `connection.changed` with attempts 1, 2, 3 of 3, and ends `.offline` (or `.error`).
  - `incompatibleRouteDoesNotRetry`: one attempt only.
  - `updateRenamesAndReplacesTheKey`: label changed; old reference removed from `MemorySecretStore`; the next turn authenticates with the new key against `FakeB4(environment: ["FAKE_B4_TOKEN": "new"])`; `profileRevision` bumped.
  - `updateRefusesAnUnknownReference`.
  - `updateKeepsASharedSecret`: two connections share a reference; replacing it on one keeps the secret.
- [ ] **Step 2: Run** `swift test --filter UsageTests` and expect FAIL.
- [ ] **Step 3: Implement** the above. Local day and week boundaries come from `Calendar.current` with `firstWeekday = 2`.
- [ ] **Step 4: Run** `swift test --filter CoordinatorTests` and expect PASS (existing inspection tests are unchanged except where an `.offline` now retries; give those harnesses zero delays).
- [ ] **Step 5: Commit** `feat(coordinator): usage.read, check retries, connection.update`.

### Task 6: UI model

**Files:**
- Create: `Sources/WorkspaceUI/WorkspaceModel+Connections.swift`
- Modify: `Sources/WorkspaceUI/WorkspaceModel.swift` (two stored properties, the event switch cases, and the `.servers` title becoming "B4 projects")
- Test: `Tests/WorkspaceUITests/ConnectionsModelTests.swift`

**Interfaces:**
- Produces on `WorkspaceModel`:
  - `public private(set) var usage: [String: ConnectionUsage]`;
  - `public private(set) var checks: [String: ConnectionCheck]`, where `struct ConnectionCheck: Equatable { var attempt: Int; var attempts: Int }`;
  - `func refreshUsage() async`;
  - `func addB4Connection(label: String?, url: String, route: String, apiKey: String?) async -> Connection?`. A non-empty `apiKey` goes through `credential.add` (label = the connection label or the host), then `connection.add` with the reference.
  - `func updateConnection(id: String, label: String?, apiKey: String?, clearKey: Bool) async -> Bool`.
  - `func checkConnection(id: String) async`, which wraps `inspectConnection`.
- Events:
  - `connection.changed` with `attempt` sets `checks[id]`; without it, it clears `checks[id]`.
  - `usage.changed` sets `usage[id].reading`.
  - `turn.finished` on a B4 connection calls `refreshUsage()`.
  - `refreshUsage()` runs on `ready` and when the Connections page appears.

- [ ] **Step 1: Write the failing tests** (`ModelHarness`, fake runtimes).
  - `usageArrivesAfterACheck`: add Codex, `model.usage[id]?.reading?.fiveHour?.usedPercent == 62`.
  - `addingB4WithAKeyStoresOnlyAReference`: add with key `"s3cret"`; `model.connections.first?.authReference?.hasPrefix("secret:") == true`; no model property contains `"s3cret"` (check `String(describing: model.connections)`).
  - `renameUpdatesTheList`.
- [ ] **Step 2: Run** `swift test --filter ConnectionsModelTests` and expect FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `swift test --filter WorkspaceUITests` and expect PASS.
- [ ] **Step 5: Commit** `feat(ui): connection usage, check progress, add and edit in the model`.

### Task 7: Shared components and formatting

**Files:**
- Create:
  - `Sources/WorkspaceUI/Theme/LLAStatusIcon.swift`: `enum LLAStatus { case ok, busy, attention, idle }` and `struct LLAStatusIcon: View` (16 pt, `@ScaledMetric`, an accessibility label, `.help`);
  - `Sources/WorkspaceUI/Theme/LLAForm.swift`: `LLAFormGroup`, `LLAFormRow(label:info:content:)`, `LLAInfoButton(text:learnMore:)` (a popover), and `LLASheetBar(cancel:confirm:confirmTitle:disabled:)`;
  - `Sources/WorkspaceUI/UsageMeter.swift`: `UsageMeter(title:window:now:)`;
  - `Sources/WorkspaceUI/UsageFormat.swift`: pure functions.
- Test: `Tests/WorkspaceUITests/UsageFormatTests.swift`

**Interfaces:**
- Produces:
  - `enum UsageFormat`:
    - `static func percent(_ used: Double) -> String`: rounded, e.g. "62%", "120%".
    - `static func fill(_ used: Double) -> Double`: clamped to 0…1.
    - `static func isHot(_ used: Double) -> Bool`: ≥ 90.
    - `static func resets(_ iso: String?, now: Date, calendar: Calendar) -> String?`:
      - under 1 h: "Resets in 38m";
      - under 24 h: "Resets in 2h 14m";
      - otherwise "Resets Thu 9:00", using the locale's short weekday and its hour format;
      - in the past: "Reset";
      - nil gives nil.
    - `static func age(_ iso: String, now: Date) -> String`: "Just now" under a minute; "As of 20 min ago"; "As of 3 h ago"; "As of 2 days ago".
    - `static func tokens(_ n: Int) -> String`: 999 gives "999"; 412_300 gives "412k"; 2_140_000 gives "2.1M"; 12_000_000 gives "12M".
  - `LLAStatus.label` gives "Connected", "Checking", "Needs attention", or "Not checked".
  - `LLAStatus.init(connection: Connection, checking: Bool, blocked: Bool)`, for connections:
    - `.busy` when `checking` or status is `.connecting`;
    - `.attention` for `.error`, `.offline`, or `.incompatible`, when `authStatus` is `.required` or `.error`, or when `blocked` (the reading's `blocked`);
    - `.ok` for `.ready`;
    - otherwise `.idle`.
  - `LLAStatus.init(server: LocalServer)`, for B4 projects:
    - `.ok` for `.ready`;
    - `.busy` for `.starting`;
    - `.attention` for `.unhealthy`;
    - `.idle` for `.stopped` or `.unknown`.

- [ ] **Step 1: Write the failing tests.** Assert every example value above, plus `fill(1.2 * 100) == 1`, `isHot(89.9) == false`, `isHot(90) == true`, and `resets(past) == "Reset"`.
- [ ] **Step 2: Run** `swift test --filter UsageFormatTests` and expect FAIL.
- [ ] **Step 3: Implement.**
  - **Meter metrics:** label and percent in `LLAFont.caption` (percent in tabular digits); 4 pt to the bar; bar 4 pt tall, corner 2, ink on `surfaceRaised` (danger when hot); reset line `caption` muted, 4 pt below.
  - **Status icon:**
    - Ink circle with a white checkmark for `.ok`.
    - A `ProgressView` in cobalt for `.busy`.
    - Danger circle with "!" for `.attention`.
    - Ghost ring for `.idle`.
    - Draw it with SF Symbols (`checkmark.circle.fill`, `exclamationmark.circle.fill`, `circle`), each 16 pt.
  - **Form row:** label column 96 (`LLA.Space.xxl * 2 + LLA.Space.l`), 12 gap, row min height 48 on the Mac, 44 on the phone. The info button is a 16 pt `info.circle` in muted, with a 30 pt target. Its popover is 240 wide with 12 padding.
- [ ] **Step 4: Run** `swift test --filter UsageFormatTests` and expect PASS.
- [ ] **Step 5: Commit** `feat(ui): status icon, usage meter, form rows, usage formatting`.

### Task 8: Connections page

**Files:**
- Create:
  - `Sources/WorkspaceUI/ConnectionCardView.swift`: replaces `ConnectionCard`;
  - `Sources/WorkspaceUI/ConnectionSheets.swift`: `B4ConnectionSheet` (add or edit) and `ConnectionNameSheet`;
  - `docs/help/connections.md`: sections `#server`, `#agent`, `#api-key`, `#b4-project-folder`, `#mode`, `#port`, `#env-file`.
- Modify:
  - `Sources/WorkspaceUI/ConnectionsView.swift`: the page; removes `addSection`, `B4AttachForm`, `RuntimeStatusView` usage;
  - `Sources/WorkspaceUI/SettingsView.swift`: the heading's `.connections` case becomes the "+" menu, and `.servers` becomes "Attach B4 project…".

**Interfaces:**
- Consumes: Tasks 6–7.
- **Card** (spec "Connection card"):
  - **Container:** padding 16, corner 12, `surface`, 1 px `rule`, 12 between cards.
  - **Header:** `RuntimeMark` 24; name `bodyStrong`; subtitle `small` muted, which reads "<Plan> · <nativeScope>", or the target in mono for B4, or "Checking… try n of 3" while checking, or the failure message when `.attention`. Then `LLAStatusIcon` and a "…" `Menu` (Check, Edit…, Sign in) on the Mac only.
  - **Body:** for Codex and Claude, two `UsageMeter`s in a 2-column grid 16 apart, 12 below the header, stacked at accessibility sizes. Claude adds `UsageFormat.age` as a caption, 8 below. For B4, two figures, "Today" and "This week". With no reading: "Usage appears after the first turn" (Claude) or "Usage unavailable" (Codex). On the phone: "Usage shows on your Mac".
- **"+" menu** in the Settings heading:
  - "Codex" and "Claude" call `addConnection(kind:)`, then `login` when the result needs sign-in.
  - "B4…" presents `B4ConnectionSheet`.
  - A kind whose runtime diagnostics say it isn't installed is disabled, with the reason as its subtitle.
- **`B4ConnectionSheet`:**
  - Title "Add a B4 connection" or "Edit B4 connection"; lede "Connect to a B4 agent server."; 24 margins; 480 wide.
  - Rows: Name; Server (mono); Agent (mono, ⓘ); API key (`SecureField`, ⓘ). In edit, Server and Agent are read-only `Text`, and the ⓘ reads "Another server or agent is a new connection." The key row reads "Saved in Keychain" with Replace and Remove, or shows a secure field when there is no key.
  - Validation under Server, only when the field is non-empty: a non-loopback `http://` shows "Remote servers need HTTPS." in danger caption, and Add is disabled.
  - Cancel and Add or Save, with Add as the default action.
  - The key value is cleared after `addB4Connection` or `updateConnection` returns, whether it succeeded or not.
- **`ConnectionNameSheet`:** one Name row, Cancel and Save.

- [ ] **Step 1: Build** `swift build` and fix compile errors from removed types.
- [ ] **Step 2: Run** `swift test --filter WorkspaceUITests` and expect PASS (`DetailMinimumSizeTests` included).
- [ ] **Step 3: Render** `B4APP_SNAPSHOT_DIR=$TMPDIR/snap swift test --filter SnapshotTests`. Inspect the connections page in light and dark against `connection-card.html`, and measure the card padding (16), the meter gap (16), and the header heights with the PIL script used for D-061.
- [ ] **Step 4: Commit** `feat(ui): connection cards with status icons and usage; add and edit sheets`.

### Task 9: B4 projects page

**Files:**
- Create:
  - `Sources/WorkspaceUI/B4ProjectsView.swift`: the page, `B4ProjectCard`, `AttachB4ProjectSheet`, `ServerLogSheet`.
- Delete:
  - `Sources/WorkspaceUI/LocalServersView.swift`: its pieces move to `B4ProjectsView.swift`.
- Modify:
  - `SettingsView.swift`: `.servers` page view;
  - `SidebarView.swift`, `Remediation.swift`, `Tests/WorkspaceUITests/RemediationTests.swift`, `README.md`, `docs/milestones.md`: user-facing "Local servers" becomes "B4 projects". Historical text in `docs/decisions.md` stays.

**Interfaces:**
- **Card** (spec "B4 projects page"):
  - **Header:** B4 mark 24; name `bodyStrong`; `LLAStatusIcon(LLAStatus(server:))`; a start/stop icon button (`play.fill` / `stop.fill`, 30 pt control, outlined); a "…" `Menu` with Restart, Inspect agents, and Show log.
  - **Meta line**, 4 below: folder in `codeSmall` muted with `~` abbreviated, 8 gap, then pills (20 tall, radius 10, `surfaceRaised`, `caption` medium) for Dev or Source, and for ":port" while running; otherwise the state word in muted small.
  - **Agents**, 12 below with a top rule: rows of min height 40 (44 on the phone), the key in mono, and a trailing `Button("Connect")` (`.llaSecondary`) or "✓ Connected" in muted small.
  - **Failure:** one danger caption line with the reason, and "Show log" as `.llaLink`.
- **`AttachB4ProjectSheet`:**
  - Title "Attach a B4 project", with no lede.
  - Rows: Folder (mono field + "Choose…", ⓘ); Name; Mode (segmented Dev / Source, ⓘ); Port (ⓘ); Env file (ⓘ).
  - Above the buttons, a caption line: "Attaching runs this project's code. Attach only projects you trust."
  - Cancel and Attach. Attach calls `model.addServer` as today.
- **`ServerLogSheet`:** the redacted tail in `codeSmall` on `codeBg`, with Done.

- [ ] **Step 1: Build** `swift build` and expect success.
- [ ] **Step 2: Run** `swift test --filter WorkspaceUITests` and expect PASS.
- [ ] **Step 3: Render** snapshots of the page with a fake B4 project (`FakeB4Project`) and compare them with `b4-project-card.html`.
- [ ] **Step 4: Commit** `feat(ui): B4 projects page with agent rows and attach sheet`.

### Task 10: Verification and records

**Files:**
- Modify:
  - `docs/decisions.md`: new D-numbers after the highest on main for the settings design, the D-022 revision, the rename, and usage staying on the Mac;
  - `docs/compatibility.md`: Codex `account/rateLimits/*`, Claude `rate_limit_event` and its `@internal` `unifiedWindows`;
  - `docs/verification.md`;
  - `docs/milestones.md`.
- Create: `docs/screenshots/settings-connections-{light,dark}.png`, `docs/screenshots/settings-b4-projects.png`, `docs/screenshots/ios-settings-connections.png`.

- [ ] **Step 1: Run the full gates:**
  - `swift format lint --strict --recursive Sources Tests Apps Package.swift`, expecting no output;
  - `swift test`, expecting all to pass;
  - both `xcodebuild build` commands from `AGENTS.md`, each expecting `BUILD SUCCEEDED`.
- [ ] **Step 2: Mac by eye.** Package with `B4APP_SKIP_NOTARIZE=1` and the Developer ID identity, relaunch, and open Settings → Connections and B4 projects. Check light and dark, and the sheets and popovers.
- [ ] **Step 3: Phone by eye.** In the iPhone 17 Pro Simulator, open Settings → Connections at default and AX3. The cards are read-only and say "Usage shows on your Mac".
- [ ] **Step 4: Live (owner's accounts, opt-in).**
  - Run one Codex check and record the real windows.
  - Run one Claude turn and record that a `rate_limit_event` arrived, with or without `unifiedWindows`.
- [ ] **Step 5: Record** the results in the docs, then commit `docs: settings connections decisions, compatibility, verification`.
