## 2026-11-14: a refusal the runtime made itself reads declined

D-229: a tool use Claude Code denied without asking, and a call B4's permissions refused, are stored `declined` in place of `failed` (Claude Code) or `completed` (B4); B4's history too. Branch `blove/runtime-refusals` from `main` 3a32af8; gates on b95c254. Adapters only: no hub, store, mirror, wire or UI change, and no migration.

### Gates

- `swift format lint --strict --recursive Sources Tests Apps Package.swift`: clean.
- `swift test`: 1904 tests in 221 suites passed.
- `npm test --prefix Tests/B4Runtime` (the published B4 CLI 0.15.8 against the fake model, Node 24.20.0): 14 of 14 passed. The new case, "real B4 settles a tool its permissions refuse as denied, on the stream and in history", gives the fixture project a tool named in `permissions.deny` and asserts that it never runs, that no prompt opens, that the `tool_result` is a serialized `ToolMessage` whose `additional_kwargs.b4_step.status` is `denied` while its own `status` is `success`, and that `GET /threads/:id/state` keeps the same step.
- The change's own tests: `ClaudeEventsTests` (a `permission_denied` frame before the tool use's result and after it; the result's `permission_denials`, a failure it does not name, a tool use id it names that the turn never saw, and nothing carried into the next turn), `B4TranslatorTests` (a denied step on a serialized message, the same words with a `completed` step and as a bare string, a `step` event before a bare result, history).
- `Scripts/docs-index.sh --check`: passes with this record and D-229.

### Not checked

- Claude Code with a deny rule or a refusing permission mode. The frame and the list are read from the schema inside the installed Claude Code 2.1.282, not from a run; which of the two arrives first, and whether both do, is not known, so the tracker handles either order.
- A Claude Code denial made by a `PreToolUse` hook.
- B4's other gates (the permission mode failing closed, an argument constraint, the workspace's path and command gates): by its source they return the same branded denial, and only `permissions.deny` was run.
- The app builds and the iOS layout tests were not run here, since nothing they compile differently changed beyond the two adapters; CI runs them.
- The running app: a declined step from either runtime's own refusal was not looked at on screen.
