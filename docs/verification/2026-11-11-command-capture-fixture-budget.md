## 2026-11-11: Command capture fixture budget

The Store merge's [post-main package job](https://github.com/cacheplane/b4app/actions/runs/43137100018/job/130914949212) completed 1,606 tests with four issues in one existing test, `runsCommandWithArgumentArrayAndCapturesOutput`. Its result was timed out, with empty captured streams and no exit code, after 54.347 seconds. The test used the production default command deadline of ten seconds. The original Store preservation regression and the complete new guard suite passed in that run. This is not a successful post-main package qualification.

The capture test now uses an explicit 120-second fixture budget while retaining its stdout, stderr, exit-code and no-timeout assertions. Its purpose is argument passing and output capture; `timesOutHungCommand` continues to exercise the 300-millisecond deadline. Production `CommandRunner` and its ten-second default are unchanged. Full-suite scheduling contention is a plausible explanation for the observed delay; no specific OS scheduling cause is asserted.

Acceptance of this focused test-only change requires a passing full package suite and all seven pull-request CI jobs. Their final status is recorded in the pull-request checks. No production, live-provider, application deployment or protocol-activation result is implied by this fixture change.
