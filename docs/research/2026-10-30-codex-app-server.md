# Research: Codex app-server protocol (verified 2026-10-30)

Legend: [V] read from the official docs or the openai/codex `main` repo on 2026-10-30; [S] from generated schema files in `codex-rs/app-server-protocol/schema/`; [U] unverified or conflicting.

## Install and start

- npm `@openai/codex` 0.166.0 (published 2026-10-29); GitHub release `rust-v0.166.0`. Homebrew is a cask: `brew install --cask codex`. [V]
- Start: `codex app-server` (stdio default; `--stdio` is an alias for `--listen stdio://`). Other transports: `--listen ws://127.0.0.1:4500` (experimental, unsupported), `--listen unix://PATH`. [V] https://learn.chatgpt.com/docs/app-server

## Wire format and handshake [V]

JSON-RPC 2.0 with the `"jsonrpc":"2.0"` field omitted on the wire. stdio is newline-delimited JSON, one message per line, no headers. Requests `{ method, id, params }`; responses echo `id` with `result` or `error`; notifications omit `id`. Exactly one `initialize` per connection followed by the `initialized` notification.

```json
{ "method": "initialize", "id": 0, "params": {
  "clientInfo": { "name": "agent_workspace", "title": "Personal Agent Workspace", "version": "0.1.0" },
  "capabilities": { "experimentalApi": false, "optOutNotificationMethods": [] } } }
{ "method": "initialized", "params": {} }
```

`InitializeResponse` is `{ userAgent, codexHome, platformFamily, platformOs }`. Capability flags: `experimentalApi`, `optOutNotificationMethods`, `requestAttestation`, `mcpServerOpenaiFormElicitation`, `requiredHumanApproval`, `explicitGatewayOauth`. [S]

## Methods

Account: `account/read` with `{ refreshToken: false }` returns `{ account: null | {...}, requiresOpenaiAuth }`; `account.type` is `apiKey` | `chatgpt` (with `email`, `planType`, `workspaceName`) | `amazonBedrock` | a GCP variant. `account/login/start` with `{ type: "chatgpt" }` returns `loginId` and `authUrl`; `chatgptDeviceCode` returns `verificationUrl` and `userCode`; `account/login/cancel` exists. Notifications `account/login/completed` `{ loginId, success, error }` and `account/updated` `{ authMode: "apikey" | "chatgpt" | null, planType }`. `account/rateLimits/read` and `account/rateLimits/updated` expose usage windows. [V][S]

Threads: `thread/start`, `thread/resume`, `thread/fork`, `thread/read`, `thread/list`, `thread/turns/list`, `thread/items/list`, `thread/loaded/list`, `thread/archive`, `thread/delete`, `thread/unsubscribe`, `thread/compact/start`, `thread/revert`. Full-history responses from `thread/resume` and `thread/read { includeTurns: true }` are deprecated; use the paginated `thread/turns/list` and `thread/items/list`. [V]

```json
{ "method": "thread/start", "id": 10, "params": { "cwd": "/Users/me/project", "serviceName": "agent_workspace" } }
{ "method": "turn/start", "id": 30, "params": { "threadId": "thr_123", "input": [ { "type": "text", "text": "Run tests" } ], "cwd": "/Users/me/project" } }
```

Turn input item types: `text`, `image`, `localImage`, `skill`, `mention`. `turn/interrupt { threadId, turnId }` ends the turn with `status: "interrupted"`. `turn/steer` exists. [V][S]

Streaming notifications: `turn/started`, `item/started { threadId, turnId, item, startedAtMs }`, `item/agentMessage/delta` (keyed by `itemId`), `item/commandExecution/outputDelta`, `item/completed { item }` (authoritative final state), `turn/completed { threadId, turn }` with `turn.status` in `completed | interrupted | failed` and `turn.error { message, codexErrorInfo?, additionalDetails? }`, standalone `error`, `thread/status/changed`. Item types include `userMessage, agentMessage, reasoning, plan, commandExecution, fileChange, mcpToolCall, dynamicToolCall, webSearch, imageView, functionCallOutput, contextCompaction`. [V][S]

Server-to-client requests: `item/commandExecution/requestApproval`, `item/fileChange/requestApproval`, `item/tool/requestUserInput` (experimental), `mcpServer/elicitation/request`, `item/permissions/requestApproval`, `item/tool/call`, `account/chatgptAuthTokens/refresh`, `attestation/generate`, plus legacy `execCommandApproval` / `applyPatchApproval`. Approval response `{ "id": 7, "result": { "decision": "accept" } }`; decisions `accept | acceptForSession | decline | cancel` plus amendment objects. `item/tool/requestUserInput` params carry `questions: [{ id, header, question, options?, isOther?, isSecret? }]` and the response is `{ answers: { "<questionId>": { answers: ["..."] } } }`. `serverRequest/resolved { threadId, requestId }` is sent after any pending request is answered or cleared. [S]

Discrepancy [U]: docs examples use `"approvalPolicy": "unlessTrusted"` and `"sandbox": "workspaceWrite"`, while the generated schema's `AskForApproval` is `"untrusted" | "on-request" | "never"` and `SandboxMode` is `"read-only" | "workspace-write" | "danger-full-access"`. Generate the schema from the pinned binary and trust it over the prose.

## Type generation [V]

```
codex app-server generate-ts --out ./schemas [--prettier PATH] [--experimental]
codex app-server generate-json-schema --out ./schemas [--experimental]
```

Output: `index.ts` barrel plus one file per type, with `v2/` (about 665 files) for thread/turn/item types. Both subcommands are experimental and version-specific. `codex debug app-server send-message-v2 MSG` exists for smoke tests.

## Authentication [V]

Credentials live in `~/.codex/auth.json` (`$CODEX_HOME/auth.json`) or the OS keyring (`cli_auth_credentials_store = file | keyring | auto | ephemeral`). `codex login`, `codex login --device-auth`, `codex login status` (exit 0 when credentials exist). ChatGPT versus API-key auth is distinguishable through `account/read` (`account.type`) and `account/updated.authMode`. Turn failures carry `codexErrorInfo` values such as `usageLimitExceeded`, `rateLimitExceeded`, `contextWindowExceeded`, `serverOverloaded`, `unauthorized`. JSON-RPC error `-32001` means overloaded; retry with backoff. The docs state app-server authentication has never been permitted for commercial or hosted services, which is compatible with a personal tool. https://learn.chatgpt.com/docs/auth

## Maturity

`codex app-server` is labelled experimental and may change without notice. Pin an exact `@openai/codex` version, regenerate types from that binary, leave `experimentalApi` off unless `requestUserInput` or dynamic tools are needed.

Not verified: the exact JSON of a complete streamed turn, `thread/resume` live-session result fields beyond the example, and whether the docs' camelCase policy strings are accepted on the wire.
