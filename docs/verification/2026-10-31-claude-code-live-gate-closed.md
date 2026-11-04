## 2026-10-31: Claude Code live gate (A03) closed

Target: the same MacBook Pro, after the owner signed in to Claude Code 2.1.282 (claude.ai, Max plan). `B4APP_LIVE_CLAUDE=1 swift test --filter ClaudeLive`, real inference, run twice.

| Step | Result |
| --- | --- |
| Inspection | `ready`, `authenticated`, 2.1.282, "Signed in as brian@brianflove.com (max) via claude.ai"; the native scope is the account. |
| First turn | "Reply with exactly the single word: pong" streamed and finished `completed`; the reply was `pong`. |
| Interrupt | A long counting turn was interrupted after its first delta; the CLI confirmed, and the result frame came back with `is_error` set and terminal reason `aborted_streaming`. The first run recorded that turn as `failed`; the translator now treats a stop it asked for (or a reason naming interrupt, cancel, or abort) as `cancelled` before it looks at the error flag, and the second run recorded `cancelled`. The fixture now emits the same shape. |
| Native resume | A new adapter on the same native session id asked what word it had been told to reply with: `pong`, `completed`. |
| Transcript | Rebuilt from the session file: four user and assistant pairs in order. |

Open on Claude: a tool-permission prompt and an `AskUserQuestion` live (fixture-tested since M2); hook callbacks and MCP messages are out of scope.
