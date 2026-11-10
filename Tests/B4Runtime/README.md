# B4 runtime integration trial

Run the real published B4 CLI against the pinned `@copilotkit/aimock` provider fixture:

```bash
npm ci --prefix Tests/B4Runtime --ignore-scripts --no-audit --no-fund
npm test --prefix Tests/B4Runtime
```

Requires Node.js 24 or newer. The tests exercise model routing and streaming, tool calls and provider requests, continuation after stopping and restarting the same project/thread, and strict failure for an unmatched fixture. They use a private temporary project and SQLite database, loopback-only aimock, and a dummy OpenAI credential; no paid provider is called and no owner app or project is used.

Synthetic diagnostics are written under `.build/B4Runtime/` and uploaded by CI for seven days. This trial verifies the CLI/runtime integration only; it does not verify UI promotion or an installed app.
