## 2026-11-06: Explicit documentation recording

Implemented the opt-in `agent-workspace docs-record` command and a Foundation-only client recorder. It subscribes before setup reads, checks global event continuity before thread filtering, requires an empty B4 thread, rejects setup activity and desync, and ends only on an explicit finish after a replay barrier and a settled-thread audit. A deadline runs even when no events arrive.

The private `b4app-docs-private-v1` output retains selected observation fields, excluding accounts, endpoints, native scope, and approval grants. Whole-field credential shapes and home paths are masked. Secrets spanning initial text and deltas or multiple deltas reject the recording. Output is owner-only and atomically linked into place without replacing an existing path. No transcript payload goes to stdout or stderr.

Verification:

- `swift build`: passed.
- Focused recording suites: 16 tests passed. Tests were run failing before implementation. A full-suite load exposed the original deadline test's short wall-clock assumption; it now uses a controllable deadline.
- `swift test`: 1,427 tests in 174 suites passed after installing the repository's pinned PostgreSQL 17.11 prerequisite. One earlier run also hit the existing notification-open timeout; its focused rerun and the final full suite passed.
- Native macOS Debug build: passed. A uniquely named, ad hoc local copy is used for demo UI targeting; this is not production-release qualification.

Live Navlog recording and publication review remain pending at this checkpoint. The website owns public normalization and immutable artifact admission. A resolved request does not expose its answer in the current protocol; the public capture must mark the decision unavailable rather than infer approval.

Decision numbering is deferred until a pull request opens, per repository instructions. No coordinator method, database schema, or UI file access was added.

## Live qualification and final audit

Two Navlog turns were submitted through the installed beta 0.1.0 app and recorded through its coordinator: an aircraft-profile lookup and a follow-up read. The recording contains 125 events and two completed turns. A complete private file was written, then normalized and reviewed in the website worktree. No flight plan was filed and this admitted recording fetched no weather. The beta executable is identified by SHA-256 `6f7340cb2288c8b0916d119c2d1623b495c11ae698363a73d672e13ae4f5a803`; the bundle does not report its source revision. Recorder source `b3930da` includes the observed custom-event JSON/label retention fix, with a failing regression test before implementation.

A separate finish-audit regression exposed a fully completed turn arriving between the replay barrier and final read. Finish now compares observed turn identities with the audit, rejecting omissions instead of reconstructing events. Its regression failed before the fix and passed afterward. Final focused suites: 17 tests passed; full Swift suite: 1,428 tests in 174 suites passed; strict Swift formatting passed. Website qualification and content-addressed assets are recorded in the b4run capture matrix. Approval and cancellation remain fixture qualification for this feature, not claims about this live recording.
