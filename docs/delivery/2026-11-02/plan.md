# CI observation design and implementation plan

The user explicitly authorized autonomous reversible implementation, so the skill approval pauses are superseded by that instruction. Existing worktree was clean. No architecture changes.

Alternatives: split native jobs (unmeasured capacity and repeated setup risk); change compiled caches (unmeasured compatibility risk); collect attempt-level timings (chosen, needed to rank either optimization). No speedup is claimed.

1. Freeze manifest and eight-run selection before candidate implementation.
2. Write negative/behavioral tests for complete attempts, pagination, timing, missing data and no success-only filtering; observe failure.
3. Implement a Python-standard-library read-only GitHub GET collector plus offline replay. Preserve allowlisted API evidence, all attempts, jobs and steps. Never use updated_at as completion or commit time as trigger. Separate job resource totals from wall span. Deny malformed/incomplete captures.
4. Add the isolated tests to existing CI lint job; preserve every current job and gate.
5. Execute local tests, real bounded collection, offline replay, held-out partial-rerun case, actionlint, shell lint and existing shell fixtures. Record limitations for unchanged native and production paths.
6. Obtain independent read-only reviews of dependency/performance, integrity/recovery, and measurement/test reliability; resolve findings and verify final content hashes.

Executable experiment: python3 .github/scripts/ci-observations.py collect --repo cacheplane/b4app --workflow ci.yml --limit 8 --output /tmp/ci-evidence.json
Replay: python3 .github/scripts/ci-observations.py report /tmp/ci-evidence.json

Acceptance is observation completeness, not release readiness. Baseline is the existing latest-run metadata snapshot; candidate adds reproducible attempt/job/step accounting. Real baseline and candidate delivery latency comparisons remain untested.
