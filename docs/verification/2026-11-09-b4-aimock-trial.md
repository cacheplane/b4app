## 2026-11-09: Real B4 with aimock trial

Scope: the actual published B4 0.15.8 CLI and its standard agent runtime, custom tool executor and SQLite checkpoints against aimock 1.47.0 on loopback. Node 24.20.0. All accounts, prompts, tools and state are synthetic. No installed app, owner project or real model provider is exercised by this first-stage gate.

### Routing and behavior

Source inspection of the installed B4 artifact found that `@b4run/langchain/dist/chat-model-factory.js` reads `OPENAI_BASE_URL` and forwards it to the model client's `configuration.baseURL`. The fixture sets that URL explicitly to aimock, uses a dummy credential and an allowlisted child environment, and refuses a non-loopback route configuration. Tests assert aimock's actual host, `/v1/chat/completions`, requested model, streaming flag and matched request journal.

Four runtime acceptance cases passed locally, zero failures/skips (13.245 seconds; 21.699 seconds during the later full-package verification):

- Text arrives in several deltas; an independent B4 thread read reports `busy` while the first partial reply is visible. A premature full-response read in the new helper initially caused this assertion to fail (`idle` versus `busy`), demonstrating that buffered final output cannot pass. Removing that eager read made it pass.
- B4 requests and actually invokes `fixture_lookup` once with the expected arguments. The tool's file ledger and B4's tool-call/result frames agree. The next model request carries the real tool result before the expected final answer.
- A completed conversation survives stopping the owned process and restarting the same B4 project on the same endpoint. The native thread and prior answer remain; the next deliberate turn includes the earlier messages and reaches aimock once. No first-turn replay or tool execution occurs.
- An unknown prompt produces a model-side 503, a B4 failed terminal response, one request without retry, and a rejected provider-journal assertion. No generic fallback answer or recording proxy is enabled.

Negative routing control: temporarily replacing only the explicit provider origin with an unavailable loopback port caused the streaming/routing acceptance case to fail with no live partial reply. The harness source was restored exactly before rerunning all four positive/control cases. The control runner reported exit 1 and `brokenProviderRoutingDetected: true`.

### Harness and limits

Every case has a new private temporary project and `.b4` directory, one aimock server and one owned real B4 child. The CLI selects an ephemeral port; restart reuses that same endpoint. Startup and shutdown use deadlines. Teardown retains synthetic B4 logs, provider request summaries without credential headers, and a tool ledger under `.build/B4Runtime/`, then removes temporary state. aimock's journal is captured before stopping it, because its `stop()` discards the journal.

The SSE reader additionally checks UTF-8 and CRLF framing when every byte arrives separately. The first CRLF fragmentation run failed on an unterminated frame; normalization now handles a CR/LF pair split between reads.

The reviewed final cases strengthen every positive turn to require one successful terminal event. The restart case now completes a real tool turn before stopping B4 and verifies the ledger remains exactly one invocation through restart and follow-up. A fresh `npm ci --ignore-scripts` followed by all four runtime cases and the SSE framing case passed five tests, zero failures/skips, in 16.813 seconds.

`swift build` passed (27.12 seconds), and strict Swift formatting, actionlint, docs-index and whitespace checks passed. The unchanged full Swift suite ran 1,474 tests in 184 suites and failed with 30 timing issues in 376.908 seconds; observed machine load averaged 749 with hundreds of Python processes and another worktree's Xcode test run active. These local failures are retained, not reported as a passing package gate. Focused B4 verification then passed all 47 tests in seven suites in 6.367 seconds. The PR's clean CI jobs are required before merging this test-only trial.

CI runs the locked test package in a separate Node job and retains synthetic diagnostics for seven days. Swift production targets and their dependency graph are unchanged. This is real-runtime/simulated-provider integration evidence; UI presentation, draft recovery through the coordinator, signed installation and live-provider behavior are separate gates. The owner authorized continuing into UI/coordinator smoke coverage after this trial passes and merges.
