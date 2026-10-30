# Research: Claude Agent SDK for TypeScript (verified 2026-10-30)

Sources: https://code.claude.com/docs/en/agent-sdk/typescript , streaming-vs-single-mode, sessions, user-input, claude-code-features, headless, cli-reference, authentication, hosting, the plan-usage support article (15036540), the npm registry, and local checks of Claude Code 2.1.282 at `/Users/blove/.local/bin/claude`.

## Package and executable

- `@anthropic-ai/claude-agent-sdk` 0.3.314 (published 2026-10-30), `engines.node >= 18.14.0`, peers `zod ^4.0.0`, `@anthropic-ai/sdk >= 0.93.0`, `@modelcontextprotocol/sdk ^1.29.0`. The SDK bundles a native Claude Code binary through optional platform packages; SDK 0.3.N bundles Claude Code 2.1.N.
- `pathToClaudeCodeExecutable: string` points the SDK at an external executable. Version match is not required, but features are gated by CLI version; detect through `SDKSystemMessage.capabilities`, not version strings.

## `query()` options (verified names)

`cwd`, `systemPrompt` (`{ type: 'preset', preset: 'claude_code', append? }`), `settingSources: ("user"|"project"|"local")[]` (omitted means all three; `[]` disables them but managed policy and auto-memory still load), `permissionMode: "default"|"acceptEdits"|"bypassPermissions"|"plan"|"dontAsk"|"auto"`, `persistSession` (default true), `includePartialMessages` (default false), `resume`, `forkSession`, `continue`, `sessionId`, `resumeSessionAt`, `env` (replaces the subprocess environment; spread `process.env` to keep `PATH`), `onElicitation(request, { signal })` (called when an MCP server requests input and no hook handled it; unhandled requests are auto-declined), `hooks`, `allowedTools`, `disallowedTools`, `abortController`, `maxTurns`, `model`, `executable`, `stderr`.

```ts
type CanUseTool = (
  toolName: string,
  input: Record<string, unknown>,
  options: {
    signal: AbortSignal;
    suggestions?: PermissionUpdate[];
    blockedPath?: string;
    decisionReason?: string;
    toolUseID: string;
    requestId: string;
    agentID?: string;
  },
) => Promise<PermissionResult | null>;
type PermissionResult =
  | {
      behavior: "allow";
      updatedInput?: Record<string, unknown>;
      updatedPermissions?: PermissionUpdate[];
    }
  | { behavior: "deny"; message: string; interrupt?: boolean };
```

`canUseTool` fires only when the permission flow falls through to a prompt; allow rules and mode-approved calls bypass it. Always pass `updatedInput` on allow (older CLIs rejected its absence).

## Streaming input

Pass an `AsyncIterable<SDKUserMessage>` as `prompt`; message shape `{ type: "user", message: { role: "user", content }, parent_tool_use_id: null }`. The returned `Query` is an async generator with `interrupt()`, `streamInput()`, `setPermissionMode()`, `setModel()`, `close()`, `accountInfo()`.

`interrupt()` resolves `{ still_queued: string[], cancelled?: string[] }` on CLI 2.1.205+ and does not clear queued messages; cancelling queued input requires the control protocol's `cancel_queued` (2.1.219+). The adapter therefore feeds exactly one submitted turn per session and never preloads further user messages.

Emitted messages: `system/init` (`session_id`, `claude_code_version`, `cwd`, `tools`, `model`, `permissionMode`, `capabilities`, `apiKeySource`), `assistant`, `stream_event` (only with `includePartialMessages`), `user` (tool results), `result` with `subtype` in `success | error_max_turns | error_during_execution | error_max_budget_usd | error_max_structured_output_retries` and `session_id, duration_ms, num_turns, is_error, total_cost_usd, usage, permission_denials, stop_reason`. Other `system` subtypes: `status`, `api_retry`, `permission_denied`, `rate_limit_event`, `auth_status`.

## AskUserQuestion

Arrives through `canUseTool` with `toolName === "AskUserQuestion"`. Input `{ questions: [{ question, header, options: [{ label, description }], multiSelect }] }`. Return `{ behavior: "allow", updatedInput: { questions: input.questions, answers: { "<question text>": "<label>" } } }`; the `questions` pass-through is required.

## Authentication

- `claude auth login [--claudeai|--console|--email|--sso]`, `claude auth logout`, `claude auth status [--json|--text]` (exit 0 logged in, 1 otherwise). Verified locally on 2.1.282: `--json` returns `loggedIn, authMethod ("none"|"claude.ai"|"oauth_token"|"api_key"|"api_key_helper"|"third_party"), apiProvider, projectsDirectory, configDirectory, email, orgId, orgName, subscriptionType`.
- `CLAUDE_CONFIG_DIR` relocates `~/.claude`.
- Precedence: Bedrock/Vertex/Foundry, then `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`, `apiKeyHelper`, `CLAUDE_CODE_OAUTH_TOKEN`, then subscription OAuth. In non-interactive mode an API key is always used when present, so the adapter builds the child environment from `process.env` minus `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN`, then confirms through `system/init.apiKeySource`.
- `--bare` reads only `ANTHROPIC_API_KEY` or an `apiKeyHelper` and never OAuth or Keychain, so it must not be used for subscription auth.
- Plan usage (support article, updated 2026-10-07): signed-in SDK and `claude -p` usage still draws from subscription limits; the October change adds monthly API credits for Max/Team that apply only with a Console API key. Anthropic does not allow third-party developers to offer claude.ai login for distributed products; a personal local tool is fine.

## Sessions

Transcripts at `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl` (`$CLAUDE_CONFIG_DIR/projects/` if set). `resume` takes the session ID from `system/init.session_id`. Since CLI 2.1.223 a session can be resumed from any working directory. `listSessions()`, `getSessionMessages()`, `getSessionInfo()` are exported helpers.

## Service process

One session maps to one subprocess over stdio; N concurrent sessions mean N subprocesses. No built-in session timeout. On abort the SDK closes stdin, waits about two seconds, then signals.

Not found: the exact `ElicitationRequest` / `ElicitationResult` field lists.
