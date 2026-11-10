# Real B4 and aimock integration trial

The owner approved this trial, its promotion into the macOS smoke suite if successful, and pull requests merged only after green checks. Execute both stages without another approval pause. This document defines the first stage; the UI promotion gets a focused follow-up plan after the runtime evidence exists.

## Goal and boundary

Exercise the published B4 runtime with deterministic model fixtures. The path is a test client → real B4 HTTP/agent runtime → aimock's provider API. Nothing replaces B4's route executor, model integration, tools, SQLite checkpoints, or HTTP event stream. This first gate does not claim that the workspace UI or a real model provider passed.

Use a dedicated Node test project under `Tests/B4Runtime`, with exact direct dependency versions and a committed npm lockfile. Start from B4 0.15.8 and aimock 1.47.0, the versions read from the registry. Node 24 is required by B4. Ordinary Swift fixture suites and opt-in paid-provider gates keep their existing contracts.

## Approach

Retaining only the current fake runtime is fast but cannot verify B4's own model routing or persistence. Recording native B4 HTTP replies would still bypass the runtime under test. Running the real runtime against aimock exercises that boundary and is the selected approach.

The fixture owns a fresh private temporary project, its `.b4` state, one aimock server, and one B4 child process. Copy a minimal real agent route into the project and resolve pinned packages from the test project's installation. Configure the model provider with an explicit loopback aimock origin and a dummy fixture credential; give the B4 child an environment allowlist. Do not load the owner's projects, environment files, credentials, or existing B4 servers.

Keep model responses in reviewed JSON fixtures. Register a harmless deterministic custom tool that records its invocation and returns a known value. Choose fixture matches that distinguish the first tool round from the answer after its result. Unexpected model requests must fail the test; a generic fallback response must never turn a missing fixture into success. Do not enable recording or upstream passthrough in CI.

The fixture helper owns process startup, health readiness, bounded shutdown, logs, request journal access, and restarting the same B4 project on the same endpoint. Only signal its own child. Teardown must run after failed assertions; startup failures must also clean up. Reports distinguish the real runtime from the simulated model.

## Acceptance cases

1. **Provider routing and streaming.** A request made through B4 reaches aimock's loopback provider endpoint. Several text deltas arrive before the terminal event, the complete answer matches the fixture, and B4 is still working when the first delta is observed. The journal identifies the model/request and contains no unmatched calls.
2. **Real tool execution.** A fixture requests the custom tool. B4 emits the tool call and result, the tool ledger proves exactly one real invocation with the expected arguments, and the second provider request carries that result before the final answer. An answer that merely mentions a tool cannot pass.
3. **Restart recovery.** Complete a turn, stop the owned B4 process, observe that the endpoint is unavailable, then restart it against the same project/state. The native thread and prior messages survive. A deliberate follow-up succeeds on the same thread with no repeated first turn or duplicate tool execution.
4. **Fixture failure control.** An unexpected provider request produces an explicit failure and a journal entry; the harness rejects it. This demonstrates that missing routing/fixtures cannot pass on a fallback answer.

Each case uses fresh state. Wait on observable readiness/events with deadlines, not arbitrary settling sleeps or automatic retries. Retain focused B4 logs, model request summaries and test results on failure; all data are synthetic.

## Integration and follow-through

Add a separate CI job using Node 24 and `npm ci`, followed by the built-in Node test runner. Dependencies are test-only and do not enter Swift packages or shipped app bundles. Run local positive cases and a negative routing/fixture control, required Swift checks, lint and independent review before PR/merge.

Success means all acceptance cases pass locally and in CI against the actual pinned B4 package. After the first PR merges, reuse the fixture in the shipped-workspace macOS harness: verify streaming and tool presentation, then unavailable/recovered runtime behavior with preserved draft and cached transcript. That follow-up also requires local UI evidence, a PR, and all checks green before merge.
