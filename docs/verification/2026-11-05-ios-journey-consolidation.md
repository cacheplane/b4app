## 2026-11-05: iOS journey consolidation

The approved navigation-first implementation consolidates 25 UI methods into 13 journeys, with
42 app launches instead of 62. All 62 legacy scenarios, 69 layout checkpoints and custom assertions
remain represented on every PR. The gate requires all 131 stable IDs from actual xcresult activities
plus exactly 13 passing UI cases and three passing component cases; missing, duplicate, unknown,
skipped, failed or expected-failure coverage is rejected. Focused coverage is local-only.

Preservation was proved before removal. The same additive source passed separate complete legacy
and journey selections on a task-owned iPhone 17 Pro / iOS 26.5 Simulator: 25 UI + 3 components and
13 UI + 3 components, each with all 131 IDs and each method's exact mapping. Both recorded SDK launch
activities and explicit launch-return markers counted 62/42. Healthy and dark composer values,
frames and rendered controls matched. An actual 8 pt alignment fault failed both the original and
replacement at the same ink assertion; an actual dismissal fault failed the corrected journey after
its initial detail checkpoint and before post-dismissal layout/completion. Faults were restored
byte-for-byte.

Three starts beyond the initial 39 estimate remain for assurance: cold sync/new-thread keyboard
state and both cold action-error detail variants. The warm error fixture was rejected after its
restored positive failed; its hook was removed. The fixture app, shipped source, locks, cache policy,
all four native build schemes and existing 5/10/15-second UI bounds are unchanged from the matched
baseline. Readiness waits for the original height/hittability predicate within the original bound.
An actual hidden-banner fault still fails.

The initial local baseline's native 28 cases and 131 markers passed, but its wrapper returned 2 after
a mid-run authoring edit. That failed command is retained; independent actual-bundle verification
and a fresh stable wrapper invocation passed. A later additive replay failed closed when its runner
looked for the manifest in a deleted Simulator container. Current installed resources were intact;
unchanged source then passed both complete selections on a fresh task Simulator and empty
DerivedData. The exact stale-path cause is unresolved. Those local checks used available package
caches and are not a network-cold or hosted timing comparison.

The matched [B2 hosted baseline](https://github.com/cacheplane/b4app/actions/runs/42167249209), source
`90d0f6a`, passed all four jobs: 1,415 Swift tests / 171 suites, all four app builds, 25 UI tests,
3 components and all 131 markers. Observed clocks:

| Boundary | B2 baseline | C2 consolidation |
| --- | ---: | ---: |
| UI step | 1,237 s | 1,361 s |
| Native job, setup to end | 1,610 s | 1,941 s |
| Four app builds | 340 s | 549 s |
| Package Build / Test | 88 / 281 s | 64 / 297 s |
| Swift cache restore / save | 21 / 0 s | 18 / 0 s |
| Aggregate macOS jobs, setup to end | 2,021 s | 2,341 s |
| Aggregate Linux jobs, setup to end | 309 s | 281 s |
| Native artifact archive | 15,150,293 bytes | 14,406,736 bytes |

The 62 SDK launch-to-return intervals totalled 357.4 s and include automation setup/idleness;
UI test-case durations totalled 911.7 s, with 283.4 s from result-summary start to the first UI case.
These intervals are separate observations, not CPU or billing measurements. Dollar cost is unknown.

[C2](https://github.com/cacheplane/b4app/actions/runs/42174769965), source `f9e52cf`, passed all four
jobs, 1,415 Swift tests / 171 suites, 13 UI tests, 3 components and all 131 markers. Hosted activities
confirmed 42 launches, 42 launch-return markers and 128 PNG attachments (136 in B2; four identical
layout blocks share captures). Its 42 launch intervals totalled 276.1 s, with a 5.874 s median versus
B2's 4.504 s. UI case durations increased to 996.7 s and summary-to-first-UI time to 320.2 s.
Native resolved package versions matched. These observations show variable execution rates and
additional transition costs; their exact causes are not established and timings are not normalized.

**C2 failed the frozen performance objective.** UI time increased 10.0%, native-job time 20.6%, and
aggregate macOS time 15.8%, despite 32.3% fewer launches. The provisional requirement remains at
least 10% lower UI-step time and no more than 5% native-job or aggregate macOS increase for each
retained integrated observation. Passing coverage does not turn C2 into a speed winner. The
consolidation is not recommended for landing as a demonstrated CI performance improvement.

The final draft PR's complete CI is the preplanned H2 holdout, including exact tested merge-tree
and parent binding. It remains pending and cannot erase C2 or change the frozen thresholds.
No durable percentile or end-to-end speedup is claimed.

Full evidence and every failed attempt remain private; only source and minimal validation metadata
are pushed. No releases, deployment, tags, shared-cache deletion or merge are part of this work.
