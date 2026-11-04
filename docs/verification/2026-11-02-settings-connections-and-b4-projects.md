## 2026-11-02: Settings, connections and B4 projects (D-081 to D-084)

Branch `blove/settings-connections-design`.

**Gates**
- `swift format lint --strict` was clean.
- `swift test` passed: 633 tests in 108 suites, after the review fixes.
- Both `xcodebuild` builds passed: macOS, and iOS for the Simulator.

**New tests**
- Protocol: `UsageTests`.
- Storage: `UsageStoreTests`, plus the migration list now includes `0006_usage`.
- Codex: `CodexUsageTests`, which parse the pinned snapshot and read it through `fake-codex.py`.
- Claude: `ClaudeUsageTests`, which parse the window variants and emit through `fake-claude.py`.
- Coordinator: `UsageTests`. These cover:
  - usage for Codex and for Claude;
  - B4 tokens counted once;
  - retries numbered 1, 2 and 3 against a closed port, and no retry on an incompatible route;
  - update (rename, replace and remove the key, an unknown reference, a shared secret);
  - the local day and week boundaries on the day daylight time ends.
- UI model: `ConnectionsModelTests`.
- UI copy: `UsageFormatTests`, `ConnectionCardTests` and `B4ProjectCardTests`.
- Snapshots: `ListSnapshotTests.b4ProjectCards` and `settingsSheets`.

**Live checks (2026-11-02, against the owner's installs)**
- Codex 0.166.0: `account/rateLimits/read`, with no inference.
  - The plan is `promax`, with `ordinaryUsageAllowed: true`.
  - There was only a `primary` window: 10080 minutes, 87% used.
  - This led to the leading-edge meter fix and the plan names (`planCodesReadAsNames`, `windowsFillFromTheLeadingEdge`).
- Claude Code 2.1.282: one `claude -p` turn on haiku with the plan login (`apiKeySource: none`).
  - One `rate_limit_event` arrived, with status `allowed_warning` and `rateLimitType: seven_day`, at 0.25.
  - Its `unifiedWindows` held only `seven_day`.

**Mac, measured on 2x snapshots**
- Shots: `docs/screenshots/settings-connections-{light,dark}.png`, `settings-b4-projects.png`, `settings-sheets.png`.
- Connection card:
  - padding 16 pt;
  - mark slot 24 pt, with 8 pt to the name;
  - 12 pt from the header to the meters;
  - 16 pt between the meters;
  - the "…" button 30 pt, at the card's 16 pt inset.
- Sheets:
  - 24 pt margins, 4 pt from the title to the lede, 16 pt to the group, 24 pt to the buttons;
  - rows at least 48 pt, with a 96 pt label column and 30 pt fields.
- Problems found and fixed while measuring:
  - Secondary pills vanished on the surface, so `llaOutline` was added.
  - Placeholders drew in ink on the Mac; empty fields are now muted.
  - The open-time check queried a connection with a turn in progress; such connections are now skipped.

**Phone (iPhone 17 Pro Simulator, default and AX3)**
- Shot: `docs/screenshots/ios-settings-connections.png`.
- The cards are read-only, say "Usage shows on your Mac", and have no "…" menu.
- At AX3 the card headers stack (mark and status above the name), after a letter-by-letter wrap was seen.
- The Settings page list drops its symbols at accessibility sizes, after "Connecti / ons" was seen.

**Review**

A whole-branch review by a fresh reviewer on Opus found no critical issues. It raised four important findings, and two minor ones were re-graded important. Each fix has a test written to fail first:

- Checks on page open ran one after another on the client's single queue and froze Send and approvals. They now run in the background (`connection.inspect background`) and skip a connection checked in the last two minutes.
- A key change during a running turn dropped the adapter mid-turn. It is now refused with `turn_active`.
- Codex's sparse `account/rateLimits/updated` overwrote a refusal. It now triggers a full read.
- A refusal outlived its reset. It now ends when the window that ran out resets.
- A check that ended early could leave a spinner turning. It now always publishes its closing event, and a snapshot clears check progress.
- A server that had never reported tokens showed "0 tokens". It now shows no figure.

The rest were deferred as minor; the PR lists them.

While re-running the snapshots, the full Mac snapshot test timed out waiting for an approval. The cause was in `fake-codex.py`, and it predates this branch: while waiting for an approval answer the fake dropped every message, so the coordinator's `thread/read` waited until it timed out. On `main` the test took about 135 s. The fake now answers reads while it waits, and the test passed three runs in three at about 38 s.

**Not checked**
- Clicking the "+" menu, the sheets' Save, and Edit against the running app. The sheets were rendered and their logic is tested; they were not driven by clicks.
- A retry seen on screen against a real unreachable B4 server.
