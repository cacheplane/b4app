# Real B4 and aimock Trial Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Verify real B4 provider routing, streaming, tool execution and restart persistence against deterministic aimock fixtures, then merge the passing trial before promoting it into UI smoke coverage.

**Architecture:** A test-only Node fixture launches one published B4 server and one aimock instance against a private temporary project. Node's test runner drives B4's real HTTP protocol, observes SSE and verifies the model/tool journals. The fixture is reusable by the later macOS harness.

**Tech Stack:** Node 24, built-in `node:test`, B4 0.15.8, aimock 1.47.0, JSON fixtures, npm lockfile.

## Task 1: Pin and inspect the runtime artifacts

Files: `Tests/B4Runtime/package.json`, `Tests/B4Runtime/package-lock.json`, `.gitignore`.

- [ ] Create the isolated test package with exact B4/aimock versions; ignore its `node_modules`.
- [ ] Install packages and inspect their exported agent/model/tool APIs and aimock journal/unmatched-request behavior.
- [ ] Use the shipped package source to select an explicit provider base URL configuration; do not infer compatibility from similar APIs.

## Task 2: Define the first observable acceptance test

Files: `Tests/B4Runtime/runtime.test.mjs`, `Tests/B4Runtime/fixtures/responses.json`, `Tests/B4Runtime/project/b4.config.ts`, `Tests/B4Runtime/project/src/app/chat/index.ts`.

- [ ] Write the provider-routing/streaming test before the fixture implementation. Run `npm test --prefix Tests/B4Runtime` and record the missing-helper failure.
- [ ] Define an explicit streaming answer and harmless custom tool schema in the route/template, using the inspected B4 APIs.

## Task 3: Implement the owned runtime fixture

Files: `Tests/B4Runtime/runtime-fixture.mjs` and the files above.

- [ ] Create private temporary state, start aimock on loopback, set the route's explicit provider URL and allowlisted child environment.
- [ ] Launch the actual pinned CLI with source `start`; poll `/healthz` with a deadline and capture focused logs.
- [ ] Implement SSE parsing, model request assertions and bounded process cleanup. At the first text delta, independently read the real thread and require its busy status while later fixture output remains pending; buffered deltas followed by a terminal event are insufficient. Run the streaming test and require that observation plus journal evidence.
- [ ] Add the failing tool test, implement the minimum fixture/tool behavior, then verify real invocation and second-round provider input.
- [ ] Add the failing restart test, implement restart on the same project/port, then verify same native thread, preserved history and exactly one deliberate follow-up.
- [ ] Add an unmatched-request negative control and make the helper reject unexpected provider requests explicitly. Verify that the control fails for its intended reason and the full suite passes.

## Task 4: CI and evidence

Files: `.github/workflows/ci.yml`, `Tests/B4Runtime/README.md`, `README.md`, `docs/compatibility.md`, `docs/milestones.md`, `docs/verification/2026-11-09-b4-aimock-trial.md`; add a decision at PR opening if required.

- [ ] Add an independent Node 24 job running `npm ci --prefix Tests/B4Runtime` and `npm test --prefix Tests/B4Runtime`, retaining focused failure evidence.
- [ ] Document exact dependency versions, boundary, commands, local evidence and remaining UI/live-provider gates.
- [ ] Run all runtime cases, `swift build`, `swift test`, strict Swift format, actionlint, docs-index and whitespace checks.
- [ ] Obtain independent review; fix important findings and rerun affected checks.
- [ ] Commit, open PR, monitor every check and merge only when green at the reviewed head.

## Task 5: Promote the successful trial

- [ ] After first-stage success/merge, write a focused UI plan using the same owned fixture.
- [ ] Extend the macOS harness to drive real B4 through the real coordinator: streaming, tool display, stopped-server failure, preserved draft/history and deliberate successful recovery.
- [ ] Verify locally and in CI, review, open a second PR and merge on green. Keep the model-provider simulation explicit in all evidence.
