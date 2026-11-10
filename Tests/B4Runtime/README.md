# B4 runtime integration checks

Run the real published B4 CLI against the pinned `@copilotkit/aimock` provider fixture:

```bash
npm ci --prefix Tests/B4Runtime --ignore-scripts --no-audit --no-fund
npm test --prefix Tests/B4Runtime
```

Requires Node.js 24 or newer. The tests exercise model routing and streaming, tool calls and provider requests, continuation after stopping and restarting the same project/thread, strict failure for an unmatched fixture, and the UI fixture owner's lifecycle. They use a private temporary project and SQLite database, loopback-only aimock, and a dummy OpenAI credential; no paid provider is called and no owner app or project is used.

The trial writes synthetic diagnostics under `.build/B4Runtime/`, uploaded by CI for seven days. Runtime checks alone do not verify UI promotion or an installed app.

The macOS UI smoke driver creates an owned private `0700` directory directly under `/tmp` named `b4smk-*`, then launches `node Tests/B4Runtime/owner.mjs <directory>` with an environment allowlist. The owner publishes `b4-runtime.json` by atomic rename with initial id `startup`, state `ready`, B4 `url`, aimock `modelURL`, temporary `projectPath`, sanitized provider `requests`, and actual `toolCalls`. Only synthetic request bodies are retained; credential headers are omitted.

Write one JSON command per stdin line: `{"id":"operation-id","command":"stop"}`, `start`, or `snapshot`. Each completed command publishes the same id. Stop closes B4 alone; start reuses its project, native database and endpoint; snapshot changes no lifecycle state. The separate `smoke-ui-stream` fixture uses 4-character chunks and 1000 ms latency to expose pending UI state.

Closing stdin or sending SIGTERM cancels startup/current readiness polling, serializes cleanup with any active command, and closes both owned servers. The final manifest reports `stopped`; malformed/unknown commands, startup failures and cleanup failures report `failed` with an `error` and a nonzero exit. The owner preserves `b4-artifacts/{b4.log,provider-requests.json,tool-calls.json}` before removing its inner temporary project. The driver owns removal of the outer directory after collecting artifacts.
