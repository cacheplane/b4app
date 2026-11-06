# UI journey consolidation design

Status: owner approved the written navigation-first design. Read-only spec review approved it. No implementation or new CI request preceded this approval.

## Goal and fixed constraints

Reduce repeated app starts while every existing behavior remains checked on each PR. Preserve current assertion meanings, appearance/screen combinations, fixture inputs and deadlines. No publishing, deployment, cache changes, runner changes or test sharding.

Remote main was verified as `a7e1ef743cebaf3704a3fa37ede72db8018df12d`. The retained local prototype is `4f9f58bac2a7da06fb79aa366e20d48c2ed7283c`, with the entire original UI helper restored. It has 25 UI methods, 62 app starts in the passing reference, three additive component methods, and a locally tested notification-clock fix. Full combined hosted acceptance is still outstanding. Local `main` is not the authoritative comparison ref.

## Approaches

1. **Real navigation journeys first — recommended.** Combine Home/detail/new-thread checks through actual taps and Back. Keep all distinct fixture/profile combinations in UI and keep startup guards. This needs almost no new fixture machinery and avoids changing production UI. Estimated result: 13 journey methods and about 39 app starts, subject to the coverage ledger and native feasibility checks.
2. **Fixture switching inside a running process.** Reconstruct models/stores and remount arbitrary roots through a fixture control channel. This could reduce starts further, but introduces reset, teardown and app-global-state equivalence questions. It is deferred until the simpler consolidation is measured. Merely invoking a URL-opening API is not proof of process reuse; the installed XCTest header describes `openURL` as a launch operation.
3. **Parallel UI workers.** Retains the current workload and repeats runner/simulator setup. It may reduce wall time at additional resource cost; it does not address duplication and is outside this phase.

## Proposed journey families

App-start counts are a design estimate, not a quota that permits dropping coverage. Retain an extra start whenever a cold-entry distinction or fixture limitation requires it.

| Journey | Proposed starts | Existing checks carried forward |
| --- | ---: | --- |
| Workspace navigation, search and scrolling | 2 | Home title and controls; real thread tap and Back; ready new-thread banner layout; search/keyboard/no-match overlap; separate long-list expanded/collapsed title pixels |
| Healthy workspace and composers | 1 | Banner absence on Home/detail; Home dock gutters; detail and new-thread picker ink, draft alignment and hit targets, reached through actual navigation |
| Sync copy journeys | 4 | Initial raw transport error, stale server error, refusal and paused state; exact existing copy/diagnostic assertions on Home and detail for each input |
| Secondary notices and dismissal | 7 | Account notice on Home; offline/action errors on Home and detail, each with and without sync failure; both dismissals; separate default stale input on both surfaces |
| Connection notice gutters | 1 | Connecting Home and detail notices, 16-point gutter and overlap/control checks, through real thread navigation |
| Startup and empty-state guards | 6 | Empty, archived, unmatched search, direct detail entry, no-ready-runtime composer and Connect your Mac; ready new-thread layout is also checked through navigation above |
| Landscape | 3 | Populated Home to detail in one process; separate empty and Connect your Mac configurations; all original orientation assertions |
| Maximum text and older timestamp | 4 | Home to detail; separate empty and Connect your Mac; separate older timestamp input on Home/detail; original layout, copy and diagnostic exclusion checks |
| Dark refusal | 3 | Home to detail to ready new-thread; separate no-ready-runtime and Connect your Mac configurations; all five original surfaces |
| Recovery | 2 | Keep separate Home/detail starts so removal is observed while each is visible; retain the existing recovery fixture action and 15-second bound |
| Sign-in and onboarding | 3 | Preserve separate camera, no-camera and onboarding startup roots and suppression of workspace notices |
| Notification open | 2 | Preserve genuine cold and warm launches, waiting state, fixture sync completion and final detail |
| Notification Back cancellation | 1 | Preserve independent warm setup, Back while waiting, later sync and remaining on the list |
| **Total** | **39** | **All current behaviors remain in UI; no component test is treated as a navigation replacement** |

The estimate reduces starts by 23/62 (37%). It does not predict a 37% runtime reduction. Existing measurements include substantial simulator/test setup, hierarchy queries, app activation and native build variation.

## Behavior-preservation rules

- Build a ledger from all 25 old methods and every loop variant, including the 69 recorded layout checkpoints, copy assertions, gutters, actual interactions, dismissals and recovery states. Each maps to a named new step and its assertions. An identical checkpoint may satisfy multiple legacy obligations only when its fixture inputs, profile, surface and state are demonstrably the same.
- Home-to-detail consolidation changes per-variant detail checks into real navigation. Dedicated direct-detail startup and cold-notification guards remain. Do not merge a unique cold-entry requirement into a warm flow.
- Preserve different raw-error inputs rather than assuming every stale case is identical. Preserve both sync-failure values for secondary notices, each original appearance matrix, and separate empty/no-ready/no-Mac fixtures.
- Do not replace real taps, search typing, Back, orientation changes or rendered-ink assertions with model state injection. The existing banner component prototype cannot replace root placement, navigation, safe areas, keyboard behavior or hit testing.
- Re-query accessibility elements after transitions. Do not reuse indexed element handles across steps or reintroduce the rejected helper cache.
- Each journey starts clean and terminates its fixture app. Cross-step state is intentional within a journey and must be checked explicitly; no cross-journey state dependency is accepted.

## Minimal fixture change

Most reuse comes from existing user navigation. Action-error journeys need one test-harness-only extension: after navigating from Home to detail, inject the same deterministic fixture error after the detail read, as the existing direct-detail fixture already does. Gate this behavior behind a journey fixture flag while old and new tests coexist. The old baseline keeps its original behavior.

No fixture HTTP service, private automation API, arbitrary command channel, root reset machinery or shipping-app hook is introduced. If the fixture cannot reach a required ready new-thread or connection state through a real control, retain the original start rather than bypass the behavior.

## Coverage gate and proof before removal

1. Diagnose the outstanding `testEveryWorkspaceSurfaceWithSyncFailure` banner-hittability failure first. The later diagnostic tree is insufficient to decide between a timing issue and a combined accessibility-frame/hit-target issue. Preserve deadlines and demonstrate that genuine hidden/overlapping content still fails any corrected check.
2. Add a small navigation/composer and notice pilot alongside the old UI tests. Run the pilots and relevant originals locally with unique obligation/checkpoint IDs. The old tests are not removed during this proof stage.
3. Check the source-to-step ledger and demonstrate actual failure detection: rendered-title/overlap or alignment fault, a dismissal/recovery fault, and a fault in a late journey step. Restore faults byte-for-byte. A deliberately omitted step must fail the coverage-result guard even if the method count matches.
4. Only then move the covered assertion blocks into journey steps and remove their duplicate test entry points. No unique assertion is deleted. Update the expected UI method count and require the complete obligation-ID set as well as both target results; counts alone are not sufficient.
5. Keep the three existing UIKit component tests and fast presentation/model tests required on every PR. Nothing moves to a scheduled gate.

Coverage markers establish execution completeness, not assertion correctness. Product/fixture-source fault controls and review of the mapped assertions establish the latter. A failure midway through a journey remains a failed gate, with the last completed and failing step identified in results.

## Measurement and bounded validation

Start a new bounded phase; the previous three-request phase remains closed with all failures retained. Existing public source-only CI push authorization persists, but it does not authorize releases or deployment.

Allow at most four new full matrices: one corrected retained-source baseline, one consolidated candidate, one reserved source-corrected candidate if required, and one final planned holdout. If the reserve is unnecessary, use only three. No unchanged-source until-green retry. Freeze source and the obligation ledger before each request; retain every result and cost.

The matched baseline and consolidated candidate must use the same production code, component coverage, cache policy, toolchain/runners, job dependencies and deadlines. The consolidation should change only UI journey organization and its necessary fixture/result-gate support.

Measure actual app starts, checkpoint/obligation completion, layout step, four app builds, full native job, package Build/Test/cache restore/save, artifact transfer/storage and aggregate runner wall. Distinguish real process starts from navigation/activation actions. First provisionally target at least a 10% layout-step reduction with no unexplained native-job/resource regression. Keep sample limitations explicit; do not claim a durable percentile or causal win from query counts or one fast failed run.

If preservation proof fails, retain the original test/start. If elapsed-time benefit is within variation, report it as unproven and keep the simpler validated configuration. No test count or launch target overrides assurance.

## Approval checkpoint

The owner approved this written navigation-first design before implementation. The precise journey count can increase when required to preserve a documented behavior; it cannot decrease by silently omitting a ledger obligation.
