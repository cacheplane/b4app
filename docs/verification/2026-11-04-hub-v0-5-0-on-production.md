## 2026-11-04: `hub-v0.5.0` on production, a rolling deploy on two tasks

- **Blocked first.** Every hub image after D-174 (`9d79481`) failed its test deploy at the migrate task: "migration 7 was previously applied but has been modified". A comment in `0007_apple_handoffs.sql` had been rewritten. D-178 (#115, `670052a`) restored the file byte for byte and pinned every migration's SHA-256 in a test. Its image deployed to the test hub (task definition 36; `/readyz` ok, 2 of 2).
- **Release.** `hub-v0.5.0` (target `670052a`; D-175 to D-178) was published. The release's new first-job check found chart 0.5.0 unpublished. The production deploy was approved, and every job succeeded, the Helm chart included: `oci://ghcr.io/cacheplane/charts/b4hub` 0.5.0, `appVersion: 0.5.0`.
- **Production after it:**
  - task definition 9, 2 of 2, rollout complete;
  - the same image digest as the test hub (`73839754db09…`);
  - 10 requests to `/readyz` split 5 and 5 between the two new instances, each answering `"relay": "ok", "instances": "ok"`.
- **The owner's Mac through the rolling deploy:**
  - The load balancer cut its link at 04:42:36.220 UTC, and it relinked to a new task at 04:42:37.455, 1.2 s later.
  - SIGTERM reached the old tasks at 04:42:54–55.
  - The release before (`hub-v0.4.0`, still on one task) had cut it for about 80 s. This is D-172 on production: the old task released the user's claim when the link was cut, not at SIGTERM.
