# Names-only test scratch scan

The observed blocker is Foundation metadata enumeration inside the synchronous shared test-cluster startup lock, sometimes on the main actor. Keep the cleanup policy intact and replace only name acquisition with `opendir/readdir` in the macOS-only storage test helper. Existing guards continue to determine whether an entry may be stopped or removed.

- [x] Profile unchanged full suite and benchmark metadata versus names-only enumeration, retaining failed mutable-directory control.
- [x] Add cleanup characterization for Unicode, files, broken links and protected unrelated entries; run against baseline.
- [x] Replace only enumeration; run cleanup/storage regressions and verify real candidate stage timings.
- [x] Run final strict full suite, isolated cold holdout and relevant native builds; retain every outcome and source identity.
- [x] Update decisions/verification and request read-only correctness/measurement review. No publication or deployment.

The benchmark is the failing performance control; no hardware-specific wall-clock assertion is added to ordinary tests. The extra characterization protects observable cleanup behavior rather than testing C-library implementation details.
