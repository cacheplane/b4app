# The conversation, from runtime event to pixel: baseline audit

This is the baseline for the transcript hill climb of 2026-11-14: how a runtime's event becomes a row on screen, what each runtime can and cannot show, and the defects found before anything was changed. The rubric, the four experiments and the gates are in `docs/verification/2026-11-14-agent-chat-hill-climb.md`; the decisions are D-233 to D-236.

Every statement here was read from the code at the baseline commit unless it says otherwise. "Risk" means the code supports it and nothing was run to show it. Nothing in this audit was checked against a live runtime.

## Baseline

| | |
| --- | --- |
| Commit | `9bb7c974` (`main`, D-231) |
| Host | macOS 26.5 (25F71), arm64, built-in display 3024 x 1964 at 2x |
| Toolchain | Swift 6.3.3, Xcode 26.6; deployment targets macOS 26 and iOS 26 |
| Build | `swift build --build-tests`, debug |
| Runtimes installed | Codex CLI 0.166.0, Claude Code 2.1.282, `@b4run/cli` 0.15.8 (`docs/compatibility.md`); none was run |
| Captures | `ListSnapshotTests.denseThreads` with `B4APP_SNAPSHOT_DIR`, 720 x 560 pt at 2x, light and dark, default text size |
| Reference | `cacheplane/threadplane` at `b21349fe3` (`~/repos/angular-agent-framework`): `tool-activity.tsx`, `activity-summary.ts`, `tool-outcome.ts`, `tools/tool-rendering-benchmark`. T3 Code is not checked out locally and was not read |

## The path

1. **Runtime.** Codex is one `codex app-server` child speaking JSON-RPC (`Sources/CodexAdapter`). Claude Code is one `claude` process per session on stream-json stdio with partial messages (`Sources/ClaudeAdapter`, D-002). B4 is HTTP and SSE to a server (`Sources/B4Adapter`).
2. **Adapter.** Each translator turns native frames into `AdapterEvent` (`Sources/WorkspaceProtocol/Events.swift`): a kind, native ids (`threadId`, `turnId`, `itemId`, `requestId`) and a JSON payload. There is no tool lifecycle type and no parent field; a tool's state is the string `status` in its payload (`inProgress`, `completed`, `failed`, `declined`).
3. **Coordinator.** `SessionService.environment(_:)` is the single writer of turns, display items and runtime requests. Items are upserted by `(threadId, nativeItemId)` with the whole payload replaced; text deltas are held in memory and published, and the final text wins (D-088). It never closes a tool item itself.
4. **Client.** `WorkspaceModel.applyToDetail` appends deltas to `ThreadDetail.liveText` and replaces items; the phone gets the same events over the relay (`MirrorTransport`).
5. **Projection.** `DenseTranscript.entries` (dense) was the only projection; normal density drew `detail.items` as stored.
6. **Views.** `TranscriptView` (scroll and follow), `TranscriptRow`, `ToolCard`, `CollapsibleCard`, `MarkdownText`, `RuntimeRequestList` (approvals and questions, between the transcript and the composer), `ComposerView`.
7. **Back.** `turn.send`, `turn.interrupt`, `turn.abandon`, `request.respond`, `thread.reconcile`. `request.respond` is guarded by the row's `pending` state and an in-memory claim; reads (`thread.read`, history load, the projections) send nothing to a runtime.

Views render and dispatch those commands only. Expanding a card, opening a dense turn and loading history are reads.

## Capability matrix

Live and history are what the adapter maps; "visible" is what the transcript drew at the baseline. Versions are those in `docs/compatibility.md`.

| Capability | Codex 0.166.0 | Claude Code 2.1.282 | B4 0.15.8 |
| --- | --- | --- | --- |
| Messages, partial text | `item/agentMessage/delta` and `item/completed`, keyed by native item id. Live and history. Visible | `content_block_delta` then one `assistant` frame per block, keyed `msgId#index`; `unfinished[messageId]` pairs them. Live; history keyed by transcript `uuid#index`, so a reconcile cannot match live text rows (risk: duplicates) | `chunk` and `message_end`, keyed `turn-N:mK` (made up). Live; history by checkpoint message, matched by turn and text. Visible |
| Tool arguments and results | Native item stored as it is (`status`, `exitCode`, `aggregatedOutput`). Visible; exit code was not drawn | `tool_use` then `tool_result`; `is_error` true is failed. Output is text only: an image-only result is stored as `""` | `tool_call`, `tool_call_args`, `tool_result`. Missing mapping before D-235: a bare result with `error: null` read failed; history marked every call completed |
| Command output while running | `item/commandExecution/outputDelta` is dropped: missing adapter mapping | Not sent by the runtime | Not sent |
| File changes | `fileChange` item with paths and diffs. Visible as a path and a plain block | A `toolUse` row (`Edit`, `Write`); no diff shape | A `toolCall` row |
| Plans and tasks | `turn/plan/updated` is dropped; a `plan` item would be a generic row: missing mapping | `TodoWrite`, `Task*`, `ExitPlanMode` are generic `toolUse` rows, not counted as steps: missing renderer | Any named event (`plan_update`) is a row of that type with its payload: fallback only |
| Delegated work | `collabAgentToolCall` is a generic row | `parent_tool_use_id` is never read; a sub-agent's frames would be top-level rows: missing mapping, unverified that 2.1.282 sends them on stdout | Not a capability |
| Approvals | Command, file change, legacy exec and patch; others declined automatically | `can_use_tool`; allow-always is sent as allow-once (D-018) | `interrupt`; allow-always becomes once when the prompt says so (D-021) |
| Questions | User-input requests (fixture-tested only) | `AskUserQuestion`; `multiSelect` is never read by the card | Unsupported |
| Interrupt | `turn/interrupt`; `interrupted` is cancelled | control `interrupt`; a stop the app asked for is cancelled | `POST /cancel`; a parked turn's prompt is declined. "Not recorded" becomes failed |
| Reconnect | Unverified | Process exit ends the turn failed (D-016) | Three reattach attempts; frames between drop and reattach may be lost (risk) |
| Imported history | `thread/turns/list`, native ids kept | Transcript JSONL, best effort (D-017); tool results never declined | `GET /state` messages |
| Open tool when the turn ends | Left to the runtime | Not closed by the adapter | Not closed by the adapter |

No adapter and no coordinator code closes a tool item left `inProgress` when its turn is interrupted, fails or loses its runtime; the stored row stays `inProgress`. Dense already drew such a step as stopped (D-223); normal density, and both densities' open cards, drew the raw word.

## Defects at the baseline

Severity is S4 (integrity or control), S3 (misleads or blocks a core task), S2 (friction with a workaround), S1 (polish). "Reproduced" has a failing assertion or a capture on the baseline.

| # | Defect | Evidence | Severity | Dealt with |
| --- | --- | --- | --- | --- |
| 1 | Scrolling back while a reply streams is undone by every token, new item and ended turn, at both densities; nothing takes the reader back to the end | Reproduced: three assertions, moved 764.5, 794 and 540 pt | S3 | D-233 |
| 2 | At normal density a step left open in a stopped or failed turn reads `inProgress` in the accent colour, and every turn's note stands at the end of the thread | Reproduced: capture `docs/screenshots/transcript-stopped-turn-before.png` | S3 | D-234 |
| 3 | B4 history restores a failed call, and a call with no result, as `completed` | Reproduced: assertions on `B4Protocol.snapshotItems` | S3 | D-235 |
| 4 | A bare B4 result with `error: null` is failed | Reproduced: assertion on `B4TurnTranslator.toolFailed` | S2 | D-235 |
| 5 | An opened B4 or Claude Code tool card draws a dump of the payload beside its output, and a running command with no output draws only the dump; exit codes are not drawn | Read from `ToolCard` | S2 | D-235 |
| 6 | A closed code fence collapses into inline code with its language joined to the first line ("bash swift test ..."); an open fence shows its backticks; there is no Copy | Reproduced: capture `docs/screenshots/transcript-code-reply-before.png` | S3 | D-236 |
| 7 | Normal density has no line saying what is running; neither density shows anything between a send and the first item | Read from the views | S2 | D-239 |
| 8 | "Allow for session" is offered where the runtime treats it as once (Claude Code always, B4 when the prompt says so) | Read from the adapters; D-018 chose it | S2 | Open; D-018 would change |
| 9 | Nothing is announced to VoiceOver: no request, failure or completion announcement exists | Read: no announcement call in `WorkspaceUI` | S2 | Open |
| 10 | Plans and task lists have no presentation of their own; Codex plan updates and command output deltas are dropped | Read from the adapters | S2 | Plans and task lists: D-243. Command output deltas: open |
| 11 | Claude Code sub-agent frames lose their parent | Risk; no fixture sends them | S2 if sent | Open |
| 12 | A Claude Code reconcile can add a second copy of each text row (live and history ids differ) | Risk when written; since reproduced in a coordinator test, behind a second defect that marked the thread missing | S3 | D-238 |
| 13 | A turn that ends with no outcome draws "Turn failed." | Read | S1 | Fixed (D-251) |
| 14 | The Mac's approval buttons come back between the reply and the resolved event; the coordinator refuses the second answer | Read; the refusal is fixture-tested | S1 | Fixed (D-253) |
| 15 | A new turn started from another device takes a reader who scrolled back to the end, as a local send does | Read (D-223 call 7) | S1 | Open |
| 16 | A Codex request the adapter declines automatically resolves without a thread id, so its row can stay pending until Codex resolves it | Risk | S2 | Open |
| 17 | Headings, lists and tables in a reply are literal text; tool output and diffs have no Copy | Read | S1 | Open |
| 18 | A thread whose first message is several windows tall opens partway up it in the running app, the later messages not laid out; also on `main` | Reproduced in the harness app on both; not in a hosted view | S2 | D-237 |

## What was reusable

- `DenseTranscript.entries` is a pure projection with thirty tests; the work extended it and did not add a second model.
- `TranscriptScrollTests` hosts the real `TranscriptView` in a window and reads AppKit's scroll view; the scroll experiment used it for the same assertion on base and candidate.
- `ListSnapshotTests.denseThreads` renders scripted threads to PNG when `B4APP_SNAPSHOT_DIR` is set; it gave the matched captures.
- `B4TranslatorTests`, `ClaudeEventsTests` and `CodexEventsTests` feed native frames to the production translators with no database.
- There is no seam from `AdapterEvent` to `DisplayItem` without PostgreSQL (`SessionService.environment` is private), so the scripted corpus (`TranscriptCorpusTests`) starts at display items and the adapter cases stay in the adapter suites. A corpus that runs native frames through adapter, coordinator and projection in one pass is the next piece of harness worth building.

## Ideas taken from the reference

From Threadplane: a call still pending when its run ended is settled from how the run ended and never read as success; a result's falsy value means nothing until a decoder for that tool says so; raw payload sits behind a disclosure; a summary names failures and never hides them under a count. D-223 already held the first and last of these for dense; D-234 and D-235 carry them to normal density, history and the card. Its separate live-region announcement per group ("label. counts.") is the model for defect 9.
