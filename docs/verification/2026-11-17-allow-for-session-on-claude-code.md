## 2026-11-17: Allow for session on Claude Code

D-250, step 2 of hill climb defect 8 (R07.1). Branch `blove/claude-session-allow`, cut from `blove/approval-choices` (D-248, pull request 225) at ef2e700e. It changes the Claude adapter (the request payload, the pending request, the allow answer), `AllowScope`, `RequestChoices` and the request card, and the CLI's request listing. No migration and no wire change.

### The gate: a live recording

Claude Code 2.1.282, real inference, a headless process as the adapter starts one (`--output-format stream-json --input-format stream-json --permission-prompt-tool=stdio --permission-mode default`) in an empty scratch directory, driven by a script that logged every control frame. The prompt asked for three Bash calls, one command each.

| Run | Answer to the first ask | Asked |
|---|---|---|
| Baseline: `touch one.txt`, `touch one.txt`, `touch two.txt` | plain allow | 3 of 3 |
| Rule only: the same three commands | allow with the suggested `addRules`, `destination: "session"` | 2 of 3: the first `touch one.txt` and `touch two.txt` |
| Every suggestion: `touch one.txt`, `touch two.txt`, `mkdir sub` | allow with all three suggestions, each `destination: "session"` | 1 of 3 |

- Each ask carried the same three suggestions: `addRules` (`behavior: "allow"`, one rule with the exact command, `destination: "localSettings"`), `addDirectories` (the working directory, `session`) and `setMode` (`acceptEdits`, `session`).
- The third run is why only `addRules` is sent: with `setMode` echoed, commands the rule did not name ran unasked.
- After the rule-only run the scratch directory held `one.txt` and `two.txt` and no `.claude` directory.
- The first attempt recorded nothing useful: with no `--permission-mode` the process started in `bypassPermissions` from the user's settings and asked for nothing.

### Tests

Failed before the change (they did not build: `sessionRules` and the `updatedPermissions` argument did not exist), pass after:

- `ClaudeEventsTests.aSuggestedAllowRuleOffersTheSession`: the recorded suggestions give `allowScope: "session"` and `allowRule: "Bash(touch one.txt)"`; a deny rule, an empty rule list and a mode change give none; a rule with no content is the bare tool name.
- `ClaudeEventsTests.sessionRulesKeepOnlyAllowRulesAndNameTheSession`.
- `ClaudeAdapterTests.decodesCanUseToolAndEncodesDecisions`: a plain allow has no `updatedPermissions`; a wider one carries them.
- `ClaudeSessionTests.aWiderAllowSendsTheSuggestedRuleForTheSessionOnly`: `fake-claude.py` suggests a rule for a settings file and a mode change, and echoes what it was sent: the one rule, addressed to the session.
- `RequestChoicesTests.aSessionAllowWithARuleSaysWhatItCovers`.

Unchanged and passing: `ClaudeSessionTests.aWiderAllowOnAToolPermissionIsRefused` (the fake's plain request suggests nothing, so `allow_always` is still refused).

Live, opt-in (`B4APP_LIVE_CLAUDE=1 swift test --filter 'ClaudeLive.*sessionAllowStopsTheSameAskLive'`), run once and passed in 10.3 s: through `ClaudeAdapter`, the first request offered the session with rule `Bash(touch one.txt)`, was answered `allow_always`, and the turn then asked only for `touch two.txt`; no `.claude` directory was written.

### Checks

- `swift format lint --strict --recursive Sources Tests Apps Package.swift`: clean.
- `swift test --filter '^(WorkspaceStorageTests|CoordinatorTests)\.'`: 525 tests in 68 suites passed.
- `swift test --skip` the same: 1532 tests in 169 suites passed.
- `Scripts/docs-index.sh --check`: passed.
- No independent review of this change was run.

### Untested

- The card and the "covers" line on screen, on the Mac or the phone.
- The installed app: this was not packaged or installed.
- Suggestions for tools other than Bash (Edit, Write, WebFetch, MCP tools). The code offers the session whenever an allow rule is suggested; only Bash was recorded.
- A resumed process asking again. It follows from the rule living in the process and was not run.
- Codex and B4 live, as in D-248's record.
