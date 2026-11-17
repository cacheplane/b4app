# Native account-session named scenarios implementation plan

> **For agentic workers:** use superpowers:subagent-driven-development for private candidate authoring and two-stage review; Root alone performs exact source/Git/network mutations. Steps are checkboxes. User restrictions override default local-test and cleanup recipes.

**Goal:** qualify all existing native scenarios with the user-approved one-minute budget per separately named scenario, preserving their original operations/assertions/cleanup and every protocol control.

**Architecture:** replace only B17/B18 outer loops with 23 ordinary named @Test entrypoints and six shared non-test helpers containing the exact original per-fixture bodies. Keep runtime implementation unchanged by this refactor. First integrate current accepted main, retaining its runtime/task-list changes, CI redesign and merge queue.

**Tech Stack:** Swift Testing, managed Xcode26.6/SwiftPM CI, existing Python compiler-control harness. Local actions limited to inert Python stdlib text/AST/hash/JSON/ZIP, configured safe Git, installed actionlint and explicitly scoped swift-format. No local tests/build/compiler/native/Node/process probes or saved helper execution.

## Fixed source and authorization

- AppRoot `/Users/blove/repos/b4run/.worktrees/b4app-protocol-client-foundation-f9a-20261111`; all commands run there with login:false. Unrelated dirty parent Dawn repo is untouched. No new worktree.
- Explicit approval: `native-named-scenario-explicit-user-approval-r1.json`; design R3 SHA f94f3fe2a6f1d6c000ad72cf19e374801224e0f6448c800336af85d6e436b26d. One minute per named scenario, entire logical groups may take longer, independent failure/cancellation/reporting/order. No parameterization.
- Current clean tooling branch head8a8a1b2cfa37a963464c0c9bfe6f5655d031e944,1319files/treece6b6cbc3b1794f25df10c1c0261ae89d8bd35ad. ToolingPR215 merged and main verified green before later main work.
- Held feature branch blove/protocol-client-foundation-f9a-20261111 at deb4a6cc4e4c56597ddff1d5acdd2122c7013a45/tree437097e648149b3faa902ffa3bbf9c2fea42c2d9,1408files. Frozen source ZIP SHA db0340b09652d053d212a3dbdbb22d24aa422b119f246ee73a8f78eec41f0d24. Existing baseline default native18P2F remains failed evidence; prior authorization to continue with baseline failures open persists. No baseline rerun locally.
- Current main da8b4cf4b04a968a46908aa0f7919d42a2e1c196/treee7d6606c0ab8b443c361224566235f4c1d6a285d,1334files; source snapshot `native-named-current-main-source-r1/`. New main CI44016917853/44015021680 successful. Four intervening commits preserve D232/D242 merge queue/D243 task lists/D244 CI redesign. Old frozen workflow line numbers are NOT combined-source truth.
- Frozen audit `native-named-scenario-scope-audit-r1/audit.json` plus mandatory current-main drift addendum are inputs. Root already verified audit pins; full original Owner55471bytes/SHA b23a77f17b0372891f638b65d15506d05dda4a5b129a4dadac3529289f574e66.

## Task 1: restore the owned feature checkout

Files: current owned Git metadata/index and tracked worktree only; private before/after proofs.

- [ ] Freshly verify all1319 current source/index blob/byte/mode pins, clean status, owned refs and approved target1408 ZIP/Git tree. Verify no ignored/untracked file collision at target-only paths, no symlink ancestors, zero effective target attributes and no other worktree checks out the target branch. Existing preflight is `native-named-branch-return-preflight-r1/` and must be fresh at mutation time.
- [ ] Root writes a once-only exact checkout grant, saves binary index/owned metadata and all immutable source authority, then configured `git switch blove/protocol-client-foundation-f9a-20261111`. Disable hooks/fsmonitor/gc/maintenance/autocrlf/global+system attrs; no force/reset/stash/cleanup/prune/filter/signing. No shared/foreign ref writes.
- [ ] Verify all1408 bytes/modes/index entries equal frozen source/tree437; tooling branch8a8 retained; source clean. Stop on mismatch without rerun/destructive repair.

## Task 2: integrate current main without losing either side

Files: merge main66-file delta plus genuine bounded conflict resolutions, compiler helper/source pins and workflow reconciliation. This is a source-integration task separate from the named-scenario policy.

- [ ] Exact main objects already acquired once without refs/tags/FETCH_HEAD updates (`native-named-main-object-acquisition-r1/`). Read latest AGENTS and published D242/D244 from source snapshot. Recheck remote main before final integration; if it advanced again, review its delta first.
- [ ] Root grants configured built-in ort merge of exact da8 into feature, `--no-commit --no-ff`, hooks/signing/rerere/external merge drivers disabled; preserve premerge source/index/owned metadata. No automatic branch commit/push. Root handles any conflict after bounded source review; never choose whole ours/theirs to discard functionality.
- [ ] Preserve all incoming runtime/task-list/adapter/storage/UI/test/docs changes and all feature runtime/owner/Store/permission changes. Sources changes here are accepted-main integration only; the named-scenario refactor adds no runtime Sources behavior. Inspect overlapping WorkspaceDatabase reconciliation/task-list logic against both parents and base; keep all original account-session and snapshot code.
- [ ] Reconcile workflow from current main as the ordinary-CI base. Preserve merge_group/scope support, non-cancelling main pushes, content-time/build-cache policy, separate debug App builds job, one iOS layout job, five-smoke-test job, required reducer names, and all Main source/path/version pins. Do not restore deleted layout coverage/shard/beta-build policy from old feature.
- [ ] Retain feature protocol extensions: package-build/test-postgres-prewarm IDs; four pre-Test focused socket/transport/foundation/Node controls; original Test prerequisite condition and exact default aggregate/complement commands; metadata sample+upload and all11 compiler-control steps; focused writer/publication/account-session controls with their exact conditions; entire PR180-only serial diagnostic job. Insert extensions into current-main package around the unchanged Build/prewarm/Test/main-cache-save layout. Keep package45min, serial45min+35min step, every1min compiler/bootstrap bound, inherited native1min, current main app-build30min/smoke20min/layout30min limits. No selector weakening, exclusions, global serialization or retry. Serial predicate remains PR180-only; no silent merge-group scope expansion. Record cache/host differences without causal claims.
- [ ] Reaudit combined pin dependencies: refresh actual changed selected source digests (notably WorkspaceDatabase) in helper and workflow sample; refresh resulting helper SHA at the actual12 protocol control references. Preserve source-name/object-path vectors, every C6/schema/field map/fixture/expected-diagnostic and all unrelated hash entries. If a genuine incoming main change affects a protected schema, stop for a reviewed plan correction; do not relax checks to pass.
- [ ] Root SPEC verifies full combined source/merge parents/base/field invariants and workflow union. Fresh independent source QUALITY verifies conflict resolutions, main behavior preservation and native/control scope. Actionlint static validation and whitespace checks only locally. Commit the reviewed integration locally, preserving source and raw Git-object proof; no push/CI before subsequent candidate acceptance.

## Task 3: author the exact private named-scenario candidate

Modify `Tests/CoordinatorTests/AccountSessionComparisonOwnerTests.swift` only within the old B17/B18 region. The merged Owner must still equal the frozen Owner before this task; if not, re-audit its new changes first.

- [ ] Dispatch fresh implementation worker with exact full task/scenario table and source spans, not whole session. Author private candidate text, exact diff, inverse/composition proof and per-scenario map. No actual source/Git/CI execution by worker.
- [ ] Replace old scalar B17/B18 methods and outer loops/counters. Preserve original Owner lines1..50 and269..end byte-for-byte; retain `@Suite(.serialized, .timeLimit(.minutes(1)))`. B16/B19/B20 and every existing lower fixture/helper/budget remain byte-identical.
- [ ] Insert these23 ordinary entrypoints (formatting may wrap only new lines):

```swift
  @Test func p2bB17PoolSlotWaitSameOwnerAllows() async throws {
    try await p2bOwnerB17PoolSlotWait(retired: false, observationIndex: 1)
  }

  @Test func p2bB17PoolSlotWaitRetiredOwnerRefuses() async throws {
    try await p2bOwnerB17PoolSlotWait(retired: true, observationIndex: 2)
  }

  @Test func p2bB17AfterConnectBeforeG3SameOwnerAllows() async throws {
    try await p2bOwnerB17ControlledWait(phase: .afterConnectBeforeG3, refused: 4, normal: 0, retired: false, observationIndex: 3)
  }

  @Test func p2bB17AfterConnectBeforeG3RetiredOwnerRefuses() async throws {
    try await p2bOwnerB17ControlledWait(phase: .afterConnectBeforeG3, refused: 4, normal: 0, retired: true, observationIndex: 4)
  }

  @Test func p2bB17AfterStatementBudgetBeforeG6SameOwnerAllows() async throws {
    try await p2bOwnerB17ControlledWait(phase: .afterStatementBudgetBeforeG6, refused: 32, normal: 3, retired: false, observationIndex: 5)
  }

  @Test func p2bB17AfterStatementBudgetBeforeG6RetiredOwnerRefuses() async throws {
    try await p2bOwnerB17ControlledWait(phase: .afterStatementBudgetBeforeG6, refused: 32, normal: 3, retired: true, observationIndex: 6)
  }

  @Test func p2bB17AfterFactsBeforeG7SameOwnerAllows() async throws {
    try await p2bOwnerB17ControlledWait(phase: .afterFactsBeforeG7, refused: 64, normal: 4, retired: false, observationIndex: 7)
  }

  @Test func p2bB17AfterFactsBeforeG7RetiredOwnerRefuses() async throws {
    try await p2bOwnerB17ControlledWait(phase: .afterFactsBeforeG7, refused: 64, normal: 4, retired: true, observationIndex: 8)
  }

  @Test func p2bB17AfterRollbackBeforeG8SameOwnerAllows() async throws {
    try await p2bOwnerB17ControlledWait(phase: .afterRollbackBeforeG8, refused: 128, normal: 4, retired: false, observationIndex: 9)
  }

  @Test func p2bB17AfterRollbackBeforeG8RetiredOwnerRefuses() async throws {
    try await p2bOwnerB17ControlledWait(phase: .afterRollbackBeforeG8, refused: 128, normal: 4, retired: true, observationIndex: 10)
  }

  @Test func p2bB17RealRelationLockWaitSameOwnerAllows() async throws {
    try await p2bOwnerB17RelationLockWait(retired: false, observationIndex: 11)
  }

  @Test func p2bB17RealRelationLockWaitRetiredOwnerRefuses() async throws {
    try await p2bOwnerB17RelationLockWait(retired: true, observationIndex: 12)
  }

  @Test func p2bB18AccountIDChangedRefuses() async throws {
    try await p2bOwnerB18ContextMutation(mutation: 0, observationIndex: 1)
  }

  @Test func p2bB18DatabaseChangedRefuses() async throws {
    try await p2bOwnerB18ContextMutation(mutation: 1, observationIndex: 2)
  }

  @Test func p2bB18HubURLSpellingChangedRefuses() async throws {
    try await p2bOwnerB18ContextMutation(mutation: 2, observationIndex: 3)
  }

  @Test func p2bB18DeviceIDChangedRefuses() async throws {
    try await p2bOwnerB18ContextMutation(mutation: 3, observationIndex: 4)
  }

  @Test func p2bB18TokenRefChangedRefuses() async throws {
    try await p2bOwnerB18ContextMutation(mutation: 4, observationIndex: 5)
  }

  @Test func p2bB18TokenRefRemovedRefuses() async throws {
    try await p2bOwnerB18ContextMutation(mutation: 5, observationIndex: 6)
  }

  @Test func p2bB18UnicodeDeviceIDBytesChangedRefuses() async throws {
    try await p2bOwnerB18ContextMutation(mutation: 6, observationIndex: 7)
  }

  @Test func p2bB18UnicodeTokenRefBytesChangedRefuses() async throws {
    try await p2bOwnerB18ContextMutation(mutation: 7, observationIndex: 8)
  }

  @Test func p2bB18NativeAbsentTokenNonNilToNilRefuses() async throws {
    try await p2bOwnerB18NativeAbsentContext(initiallyNil: false, observationIndex: 9)
  }

  @Test func p2bB18NativeAbsentTokenNilToNewRefuses() async throws {
    try await p2bOwnerB18NativeAbsentContext(initiallyNil: true, observationIndex: 10)
  }

  @Test func p2bB18MetadataAllowedThenGateAndOwnerReplacementNeverRetargets() async throws {
    try await p2bOwnerB18MetadataGateAndReplacement(observationIndex: 11)
  }
```

- [ ] Implement these six private ordinary async-throws helpers inside the suite in the replacement region; their bodies are the exact original withFixture blocks, dedented only, with observationIndex retaining its argument name:

```swift
private func p2bOwnerB17PoolSlotWait(retired: Bool, observationIndex: Int) async throws
private func p2bOwnerB17ControlledWait(phase: AccountSessionComparisonPhase, refused: UInt, normal: UInt, retired: Bool, observationIndex: Int) async throws
private func p2bOwnerB17RelationLockWait(retired: Bool, observationIndex: Int) async throws
private func p2bOwnerB18ContextMutation(mutation: Int, observationIndex: Int) async throws
private func p2bOwnerB18NativeAbsentContext(initiallyNil: Bool, observationIndex: Int) async throws
private func p2bOwnerB18MetadataGateAndReplacement(observationIndex: Int) async throws
```

Complete body composition is fixed by audit's originalFixtureSpan records: original1-based inclusive56..91,101..127,132..161,169..207,212..231,234..266 respectively. These full bodies are supplied from the immutable Owner, not reimplemented. Preserve UInt phase tuples (4,0),(32,3),(64,4),(128,4), all raw joins/holds/real waits, every rollback/defer and expected command/refusal/cleanup sequence, exact Unicode tokens and context restoration. Final B18 metadata/gate/owner-replacement remains ONE complete body. Do not hoist/share any fixture, endpoint/root, owner/API/task or mutable state; wrappers call one helper once with literal stable indices.

- [ ] Inert source proof:23 unique wrappers,12+11 exhaustive map/21linked+2unlinked, no extra discovered helper tests, Owner26+storage15=41 native methods. Preserve104 selected protected declarations (18native+86companions) exactly. Companion86 is accepted carrier16+writer53+publication17; writer's55 physical declarations/dedicated lane55 are separate. Source/schema constant hashes and all old prefixes/suffixes stay exact.
- [ ] Root SPEC then fresh independent source QUALITY. Any defect returns to same author; source QUALITY starts only after SPEC passes. Installed direct swift-format may be applied only to changed file/new region under Root authority; no compiler/test invocation and no unrelated reformat.

## Task 4: apply source and pin refresh

Modify Owner, `Scripts/check-owner-carrier-compiler-controls.py`, and `.github/workflows/ci.yml` only for exact reviewed candidate+genuine digest replacements beyond task2 integration.

- [ ] Root fresh once-only source grant applies exact candidate; verify full tree/index and all unrelated bytes/modes unchanged from accepted integration. No Runtime Sources changes attributable to refactor.
- [ ] Compute actual Owner SHA; replace its one ACCOUNT_SESSION_SOURCE_PINS value in helper and workflow. Recompute helper SHA and replace actual12 workflow helper literals, protecting every other byte of helper/protocol blocks. No fabricated digest or old source claim. Fresh Root SPEC then independent source QUALITY checks whole combined result, selectors, pins and protected constants.

## Task 5: record the approved policy and gate scope

Create one fresh allocated `docs/decisions/D-NNN-account-session-comparison-scenarios-have-independent-test-budgets.md` and one `docs/verification/2026-11-16-account-session-comparison-named-scenarios.md`. Save this implementation plan under repository `docs/superpowers/plans/2026-11-16-account-session-comparison-named-scenarios.md` only after branch restoration; private copy is the source until then.

- [ ] Root performs complete paginated main/tree/open-PR file allocation through readonly REST; no local docs-index helper execution. Published D242-D244 already exist; do not guess245, renumber any published decision, or rewrite historical dated evidence. Recheck allocation before publishing new own file; rename only own unpublished new file if needed.
- [ ] Decision records explicit approval, per-scenario vs old group budget, changed isolation/reporting/order and unchanged operation/cleanup/runtime constraints. Verification starts UNQUALIFIED/CI pending and preserves historical20/106 and all2160open observations; current planned41+86=127 is a source denominator only. Add actual CI evidence later with exact source/run identities. No blanket20→41 replacements: frozen docs had none and all dated records remain historical. Preserve current main compatibility/milestones/task-list wording; add a precise pending/qualified note only if needed by actual results. No edits to owner roadmap/generated indexes.

## Task 6: commit, managed CI and evidence acceptance

- [ ] Final Root SPEC and fresh independent source QUALITY cover all combined paths, full source inventory/tree/index, genuine pin changes and docs. Locally run only permitted static actionlint/scoped-format/whitespace checks; no local build/tests/SDK/probes. Baseline RED is already the archived default18P2F time-limit evidence and explicit user policy change; do not fabricate a new failing test/source rollback or claim that old evidence ran the new41methods.
- [ ] Root creates one normal local commit of reviewed refactor/docs (integration commit remains separate), then rechecks main/current PR180 head and active CI. If main advanced, review exact new delta/combined source before pushing. One normal push, no force/cancel/selective rerun. PR180 stays draft/no-auto/HELD and is not enqueued. Main now requires merge queue D242; future authorized merging must honor it, never bypass protection.
- [ ] Observe complete ordinary CI and protocol extension steps to natural terminal. Capture actual synthetic/head/base/tree/source/helper/workflow/build/sample identities, all jobs/raw logs/artifacts/ZIP hashes+CRCs+server digests; no saved helper execution unless separately Root-read/adopted exact permitted metadata-only helper. No local compiler/native experiments.
- [ ] Require all23 exact named methods actual terminalPASS (all12 B17/11 B18 stable fixture indices), all18 other native methods and selected86 companions in every applicable default/focused/diagnostic context. Default aggregate parallelism stays the default; focused/serial success never substitutes for default failures. Keep C6 33receipts/11profiles/11summaries and all existing bootstrap/schema/field/fixture limits; actual new source/runtime proof only, no transfer from old held metadata. Preserve original per-fixture marker chains/monotonicity; global case order can differ. Keep family/parameter/source/control denominators separate.
- [ ] Entire current/new failure history remains separately recorded and OPEN; no unrelated87baseline failures or old observations silently closed by native success. A failed/missing/skipped/cancelled named case or required control blocks qualification. If correct source still fails, diagnose actual managed evidence before proposing a fix; no relaxed thresholds/exclusions/retries.
- [ ] After Root evidence SPEC and independent evidence QUALITY, append actual gate outcome and update PR description around final behavior/validation/holds. If docs changes require a new push, revalidate the resulting source via ordinary CI as appropriate. No publication, activation, new production deployment, PR180 merge or release authority is supplied by this test-policy approval. Keep all later-stage holds until their own work/acceptance is complete.

## Review and recovery

All mutations need fresh exact bounded Root grants with before/after source+owned metadata preservation; consume each once. Never execute old saved metadata/native/compiler helpers, never reset/stash/clean/prune, never change foreign refs/config, never infer physical quiescence or root cause from timing. No extra user confirmation for routine authorized implementation/integration; only a material new design conflict outside this approved policy requires clarification. Plan reviewer may request corrections before task1; downstream source and evidence reviews remain mandatory.
