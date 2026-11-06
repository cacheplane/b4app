# UI Journey Consolidation Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline, task by task. Read-only review agents are allowed; do not delegate implementation.

**Goal:** Preserve every existing per-PR UI behavior while consolidating 25 methods/62 app starts into about 13 journey families/39 starts, then measure the complete CI impact.

**Architecture:** Keep the shipped views and existing isolated fixture app. Reuse a running app through real navigation; preserve cold entry/profile/fallback starts. Add a manifest of the 62 legacy launch scenarios and their 69 layout checkpoints; require execution markers as well as target counts. No arbitrary fixture-reset service or production hook.

**Tech Stack:** Swift6, XCTest/UIKit/SwiftUI, XcodeGen, Python standard library, existing GitHubActions runners/caches.

## Task1 — Isolate source and establish the correctness baseline

**Files:** approved spec at `docs/superpowers/specs/2026-11-05-ios-journey-consolidation-design.md`; existing `Tests/iOSLayout/UITests/BannerLayoutTests.swift` and `Tests/iOSLayout/Harness/LayoutApp.swift`; private evidence under the primary worktree's `docs/delivery/2026-11-05/ios-journey-consolidation/`.

- [ ] Commit approved spec and this reviewed plan on the clean branch rooted at4f9f58b. Keep the private evidence ancestry out of this branch.
- [ ] Clone only local build outputs for practical native checks, recording precomputation; clear relocated ModuleCache directories inside the new copy only. Do not change hosted cache policy.
- [ ] Inspect the prior C0 failure artifact and run `testEveryWorkspaceSurfaceWithSyncFailure` on a task-owned Simulator with the unchanged helper. The recorded failure is a real red result, not a synthetic integration.
- [ ] Gather parent/content frames and hit results if reproduction differs. The failed tree shows a combined sync-banner frame fromy0through151.7 and actual text below the navigation bar; do not assume a missing visual banner from parent hit-testing alone.
- [ ] Correct only demonstrated readiness/visibility classification: judge actual visible contents when a combined accessibility frame includes the top safe area, retain all navigation/pixel/geometry assertions, and wait for the actual condition within the original10-second readiness bound. Use XCTest condition waiting, not an added fixed delay. Never carry indexed handles across transitions.
- [ ] Run the affected case and a real source-fault negative control that hides/overlaps the banner or title. The corrected check must still fail. Restore faults byte-for-byte and verify green. If evidence does not support a correctness change, retain the original check and document the unresolved condition; do not weaken it to consolidate.
- [ ] Run full Swift build/test (existing1415/171 expected) and full native25UI+3component checks locally where available. Keep all failures and deadlines. No live-provider flags.

## Task2 — Add a behavior-level result contract before changing journeys

**Create:** `Tests/iOSLayout/UITests/coverage.json`, `Tests/iOSLayout/UITests/JourneyCoverage.swift`.
**Modify:** `Tests/iOSLayout/project.yml`, `Tests/iOSLayout/UITests/BannerLayoutTests.swift`, `Scripts/verify_ios_layout_results.py`, `Scripts/test-ios-layout.sh`, `Scripts/tests/test_ios_layout_results.py`.

- [ ] Encode each old method with its launch count (sum62). Give scenarios stableIDs `<oldMethod>#<ordinal>` and layout checkpoints `<scenario>/layout#<ordinal>` (sum69). Most scenarios have1layout; sign-in3have0, navigationhas3, scrollinghas3, recovery2each, and OtherNotice scenarios7–10have2each.
- [ ] Package the manifest as a UI-test resource. In legacy mode, launch assigns a pending scenario ID; the next launch or an async teardown block completes it after assertions, checking its expected layout count. `checkLayout` emits a checkpoint attachment only after its original assertion block. Marker names use a stable `coverage:` prefix, with actualcase outcomes still authoritative.
- [ ] In journey mode, scenario/checkpoint IDs are explicit. One shared assertion block may emit multiple distinct legacy IDs only with identical input/state/profile proof. The helper must not fabricate IDs for unexecuted steps.
- [ ] Write Python unit negatives first: missing late checkpoint, missing scenario, duplicate ID and unknown ID must reject an otherwise passing result with correct target counts. Run red before implementing `verify_coverage`.
- [ ] Extend the public reader to collect marker names from actual xcresult activities for UI cases. Require exactly the131IDs for a full run, plus all required targets/counts/results. Missing activity/result extraction is failure, not empty success.
- [ ] Keep focused local runs explicit: derive allowed subset from the selected legacy/pilot/journey method mapping only when a focused-coverage override is set. CI always requires the full contract. Component-only diagnostics require no UI markers but cannot pass the full CI mode.
- [ ] Verify against real native results and negative cases. Marker completeness is execution proof, not replacement assertion proof.
- [ ] Freeze the corrected/instrumented baseline with original25UI+3components, then request full matrixB2 (first of at most4new requests). Same source-only validation-ref policy and minimal public metadata; all archives remain private.

## Task3 — Add navigation pilots alongside the originals

**Create:** `Tests/iOSLayout/UITests/BannerJourneys.swift`.
**Modify:** shared helpers in `BannerLayoutTests.swift` (visibility only as needed to share), and fixture `LayoutApp.swift` for a journey-only action-error injection flag.

- [ ] Add navigation/search/scroll and healthy-composer pilots without removing old test methods. Reach Home→thread→Back and new-thread through actual taps. Keep the long-list seed separate.
- [ ] Give every original assertion/fixture variant an owner in the ledger before aliasing markers. Preserve picker inputs; if navigation changes them, retain a fresh start rather than silently changing the test.
- [ ] Add notice pilot paths. The new fixture flag allows the existing after-detail-read action-error injection for a journey that started on Home; the old25 tests do not set this flag and retain original behavior. No production file changes.
- [ ] Run legacy reference and pilot selections separately from the same additive source so duplicate marker sets cannot masquerade as one passing run. Compare scenario/checkpoint sets for the migrated obligations and inspect rendered screenshots.
- [ ] Inject actual source faults in a rendered-title/alignment check and in a late step such as dismissal or recovery. Verify assertions fail and the missing/aborted checkpoints are diagnosable; restore exact source and green. Never use an unconditional XCTest failure as visual-equivalence proof.

## Task4 — Complete and prove all journey families, then remove only duplicate entry points

**Files:** `BannerJourneys.swift`, `BannerLayoutTests.swift`, `coverage.json`, `Tests/iOSLayout/README.md`.

- [ ] Implement the approved13-family table: navigation/search/scroll2starts; healthy composers1; sync copy4; secondary notices7; connecting gutters1; startup/empty guards6; landscape3; max-text/older4; dark refusal3; recovery2; entry roots3; notification open2; notification cancel1. Sum39, retain more starts whenever necessary.
- [ ] Reuse existing assertion helpers and exactcopy/gutter/ink/hit/recovery conditions. Keep distinct error inputs, both sync flags and every original surface/profile combination. Do not optimize screenshot/query acquisition in this phase.
- [ ] Preserve the genuine cold/warm notification launches, independent cancellation setup, all three auth entry roots, no-ready/no-Mac and direct-detail startup guards.
- [ ] Execute the complete legacy and complete journey selections locally from additive source, with the full131-ID requirement separately satisfied in each. Preserve every failure; do not select only passing subsets.
- [ ] Conduct read-only coverage review of all25oldmethods,62scenarios and69layoutcheckpoint obligations, including custom assertions after common layout checks. Resolve gaps before removal.
- [ ] Only after proof, remove old duplicate test entry points and retain13journeys (or the necessary higher count). Keep legacy IDs in the manifest and result guard. Update default/CI target counts to the actual new method count plus3components; do not lower the obligation set.

## Task5 — Measure the integrated candidate and close honestly

**Modify:** `.github/workflows/ci.yml` only for source-validation triggers/counts; `docs/verification/2026-11-05-ios-journey-consolidation.md`, `docs/milestones.md`; read-only private measurement tools/manifests.

- [ ] Freeze the consolidated source and full obligation manifest. Strictformat, actionlint, shellcheck, Python guard tests, docs-index and diff checks must pass before commit/push. No private evidence in public ancestry.
- [ ] Request full matrixC2; all4jobs, completeSwift coverage, all4appbuilds and fullUI/component obligations required. Compare with B2 on identical production code/cache/runners/deadlines and named boundaries.
- [ ] Measure actual process starts separately from navigation/activation events; require checkpoint/scenario completeness. Report native four builds, layout step, target case sums, nativejob wall, package Build/Test/cache, uploads, artifact sizes and runner wall. Unknown timestamps/cost stayunknown.
- [ ] Up to4newfullmatrices: baseline, candidate, one relevant source-corrected reserve if needed, finalplannedholdout. If reserve unnecessary use3. No until-green unchanged retries. Include every failure and cost; never relabel a failed run as a coverage-equivalent speed winner.
- [ ] Provisionally seek≥10%layoutstep improvement with no unexplained native/resource regression; show individual observations/variation, no durable percentile claim. Reject unsupported optimizations rather than dropping obligations.
- [ ] Remove temporary validation triggers from the final review branch, retain exact lineage/static input-reuse proofs for documentation-only changes, and obtain scoped final source/coverage/measurement review. Do not merge, publish or deploy.

## Execution choice

Execute inline in this session, as requested by the owner. Read-only reviewers may audit the spec, plan, coverage and results; implementation remains with the primary agent. User approval already covers the written spec; do not repeat the same approval request when no material design change occurs.
