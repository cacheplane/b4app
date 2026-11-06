## 2026-11-05: Additive iOS test layers and bounded CI measurements

Historical snapshot: this record describes the retained layered prototype before journey consolidation,
when all 25 UI entry points remained. The final source uses 13 journeys while preserving every
legacy obligation; see [the consolidation record](2026-11-05-ios-journey-consolidation.md).

The owner required every behavior to stay checked per PR, replacement coverage before removing UI checks, unchanged deadlines, and no publication or deployment. All 25 existing UI tests remain. This is a prototype with incomplete hosted acceptance, not a demonstrated CI speedup or a ready-to-land change.

### Retained source

- `SyncBannerContent` supplies the actual app banner's visibility and copy. Three Swift test methods cover nine state combinations and fixed-clock today/older timestamps.
- Three component methods host the shipped `SyncBanner` through UIKit. They check healthy height, actual text pixels, the marker inset and multiple visible maximum-text lines. The result script independently requires all 25 UI and three component methods, rejecting missing, partial, skipped and failing targets.
- The first component assertions incorrectly passed an actual one-line source fault. The strengthened pixel line-band assertion rejects that fault; doubled padding also fails. Restoring the exact banner source passes all three tests. This proves these specific faults are detected, not complete text visibility or navigation replacement. Renderer locale, calendar and time zone are recorded in an attachment.
- The entire UI-helper optimization was reverted to the exact `a7e1ef7` file after inconclusive timing and UI failures. The temporary validation-branch push selector was removed. Normal main-push/PR triggers, caches, deadlines, four native schemes and other jobs remain.

### Hosted observations

The reused baseline's actual PR merge checkout `9ccac20` has the same tree as `dd51e3c`/`00fe9ca`; `a7e1ef7` adds three documentation files only. Each candidate was frozen on a distinct validation ref. All new requests were first attempts; no until-green reruns were issued.

| Case / source | Result | Four app builds (s) | Layout step (s) | Native job (s) | Package Build / Test / cache restore+save (s) |
| --- | --- | ---: | ---: | ---: | --- |
| [B1 baseline](https://github.com/cacheplane/b4app/actions/runs/42140330972), `dd51e3c` | All jobs pass | 420 | 1,138 | 1,579 | 90 / 244 / 22+0 |
| [A0 helper cleanup](https://github.com/cacheplane/b4app/actions/runs/42145659800), `f8d1c77` | All jobs pass | 517 | 1,313 | 1,860 | 112 / 299 / 25+0 |
| [P0 initial prototype](https://github.com/cacheplane/b4app/actions/runs/42147553594), `40cfbed` | Native UI failure | 707 | 1,248 | 1,990 | 65 / 258 / 17+0 |
| [C0 corrected pixel oracle](https://github.com/cacheplane/b4app/actions/runs/42148716590), `bda26dd` | Native UI and package failures | 454 | 1,347 | 1,832 | 65 / 225 / 17+0 |

Job boundaries are setup through completion; the layout step includes harness construction, startup, tests and teardown. Package Test includes test compilation. Native dependency-cache and upload costs are included in native job wall. CPU and monetary billing are unknown. The cancelled existing main run `42143845410` is retained separately and is not a baseline.

A0 reduced recorded all-elements queries from 684 to 315 while retaining 62 launches, 136 PNG and 69 text attachments. Its layout step nevertheless grew 15.4%; native job wall grew 17.8%. That query reduction is a rejected experiment, not a retained speedup. The 25 UI case-duration sum was 903.1 seconds at baseline and 1,018.6 seconds for A0; summary-start to first UI case was 213.0 and 257.7 seconds. These are separate boundaries, not isolated simulator-startup measurements.

The prototype component bodies totaled about 0.27–0.29 seconds in hosted results. The interval after the final UI case through result completion was 26.7–32.4 seconds, including component-host/teardown work. One component has no recorded start time; its duration is retained and the complete component timestamp span stays unknown. Failed UI cases ended some internal scenario loops early, so P0/C0 timings cannot establish equivalent passing speedups. One baseline and distinct changed candidates do not establish a durable improvement or tail percentile.

### Failures and local follow-up

P0 failed `testRefusalBannerInDarkMode`: a cached indexed banner handle no longer resolved inside the later diagnostic map. A local fresh-query variant passed that case, but the whole helper experiment was subsequently reverted. C0 separately failed `testEveryWorkspaceSurfaceWithSyncFailure` when no candidate passed its visibility/hittability filter although the later diagnostic tree contained a banner. Its exact cause remains unresolved; the original helper is retained without relaxing its assertion.

C0 also failed `a_missing_notification_thread_has_a_bounded_honest_failure`. A deterministic clock reproduced a relative retry sleep scheduled at 15.25 seconds after the clock advanced to the original 15-second deadline. The local fix captures an absolute wake-up capped at that deadline. The retry interval, 15-second window, 60-second test guard and separate I/O timeout remain unchanged. The new regression fails the former implementation without waiting on wall time.

The unpushed clock follow-up passed all 14 notification tests, the complete 1,415-test/171-suite Swift run, `swift build`, unsigned macOS/iOS app builds and native test-target compilation. After the complete helper rollback, all UI/component targets compile again. These local results do not certify the final combined source in hosted CI.

The three-new-matrix phase budget is exhausted. Full hosted validation of the retained prototype/clock fix and diagnosis of the remaining banner-hittability failure are required before PR acceptance. No UI checks were removed, no release was published, and no deployment or merge ran.
