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
