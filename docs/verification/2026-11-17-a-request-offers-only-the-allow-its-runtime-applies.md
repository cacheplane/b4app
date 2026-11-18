## 2026-11-17: a request offers only the allow its runtime applies

D-248, hill climb defect 8 (R07.1). Branch `blove/approval-choices` from `main` 167bd71d. It changes the three adapters (the request payload, and what each does with `allow_always`), `SessionService.requestRespond`, the request card in `WorkspaceUI`, and the CLI's answer hint. No migration and no wire change.

### What the runtimes do

Read, not observed live:

- Codex 0.166.0's schema (`codex app-server generate-json-schema`): `acceptForSession` on a command approval is "future prompts in the same session-scoped approval cache should run without prompting"; on a file change, "future changes to the same files".
- Claude Code: the adapter sent the same plain allow for both allow buttons (D-018).
- B4: `Tests/B4Runtime/node_modules/@b4run/cli/docs/permissions.md` and `tools.md` describe an **Always** answer kept by B4, and `{ tool, allowAlways: false }` as an entry that asks on every call.

### Tests

Failed before its change, passes after:

- `SessionTests.aWiderAllowOnARequestThatOffersNoneIsRefused`: before the coordinator's check, the refusal came from the adapter with the adapter's message. Now the coordinator refuses first; the request stays pending and `allow_once` resolves it.
- `RequestChoicesTests` (six tests): did not build before `RequestChoices` existed.

Written with the change and not seen failing, because the code went in with them:

- `AllowScopeTests`.
- `CodexEventsTests.approvalsOfferTheSessionAndOtherRequestsDoNot`.
- `B4TranslatorTests.aPromptThatAsksEveryTimeOffersNoWiderAllow`, the `always` scope in the existing parked-turn test, and `resumeDecision` throwing for an every-call prompt.
- `ClaudeSessionTests.aWiderAllowOnAToolPermissionIsRefused`: the fake's permission offers no scope, `allow_always` is refused with `unsupported_capability`, and `allow_once` then completes the turn.

Unchanged and passing: the coordinator's B4 test that answers `allow_always` and reads "Approved (always)", and the Codex `acceptForSession` mapping.

### Checks

- `swift format lint --strict --recursive Sources Tests Apps Package.swift`: clean.
- `swift test --filter '^(WorkspaceStorageTests|CoordinatorTests)\.'`: 525 passed.
- `swift test --skip '^(WorkspaceStorageTests|CoordinatorTests)\.'`: 1525 passed.
- `Scripts/docs-index.sh --check`: passes.

### Untested

- The card on screen, on the Mac or the phone: the three button sets and the toggles were not seen, and no UI test presses them.
- The toggles with VoiceOver and at large text sizes.
- The CLI's answer hint: no test reads it.
- A phone's relayed `allow_always` refused end to end; the coordinator path it takes is the one tested.
- Any live runtime: that Codex's session allow and B4's always behave as their schema and docs say.
- Whether Codex takes `acceptForSession` on every command approval: its experimental schema has `availableDecisions` per prompt, which the adapter does not receive (`experimentalApi: false`), so a network approval may show "Allow for session" where Codex would not offer it. Needs a live recording.
- B4 interrupts that are not permission prompts: every interrupt is answerable and scoped `always` unless it says `allowAlways: false`, as before this change; B4's other interrupt types were not checked.
- The two `xcodebuild` app builds were not run for this change.

### Review

One independent read of the branch: no critical or important finding. Left as they are, minor:

- Multi-select ticks are keyed by label, so two options with the same label tick together, and an option with no label cannot be chosen.
- The coordinator checks for the wider allow before `decline`, so `--accept-session --decline` together on a request with no scope is refused where it used to decline; and `allow_always` sent to a question gets the approval wording.
