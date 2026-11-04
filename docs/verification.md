# Verification record

Gate results and unresolved checks, one file per record in [`docs/verification/`](verification/), named `YYYY-MM-DD-<slug>.md`. Each entry names what was exercised, how, and what remains open. Live checks are only those run on the target Mac against real runtimes.

## 2026-11-04: Production on `hub-v0.4.0` and two tasks

- **Release.** `hub-v0.4.0` (target `d0a7116`, D-161 to D-172) was published and its production deploy approved. Prod runs task definition 8, whose image digest (`62bcec18749d…`) is the one the test hub passed the two-task check on (task definition 30). The release's "Publish the Helm chart" job failed only because chart `0.4.0` was already in `ghcr.io/cacheplane/charts`; the hub deploy itself succeeded.
- **Two tasks (runbook 13, #107).** The CI plan on #107 held only the ECS service and the target group, and the approved apply reported "0 added, 2 changed, 0 destroyed". `update-service --desired-count 2` followed, and the service went stable at 2 of 2 on task definition 8. Checked:
  - deployments run at 100/200;
  - the target group has a 5 s deregistration delay and `app_cookie` stickiness on `b4hub-instance`;
  - both targets are healthy;
  - 12 requests to `https://hub.b4.run/readyz` split 6 and 6 between the two instance ids, each answering `"relay": "ok", "instances": "ok"`.
- **The owner's Mac.** The release deploy was the last on one task, a stop-then-start, and cut the link for about 80 s (01:29:59 to 01:31:19 UTC). The scale-up to two tasks did not touch it: no link closed or relocated afterwards.
- `private_tasks` (the "next" tier's NAT) is still off; the tasks run in public subnets as before.

## 2026-11-04: Rolling deploys on two tasks after D-172, live

Each file begins with `## YYYY-MM-DD: <title>` and holds the record under it, with its own `###` sections where it has them. Since D-174 the record is a directory so that parallel pull requests, each adding a file, never conflict.

- Newest first: `Scripts/docs-index.sh` writes `docs/verification/index.md`, one line per record. It is generated and gitignored (a committed list would conflict between pull requests); on GitHub, the directory listing is the index.
- Adding a record: `AGENTS.md`, "Decisions and gate records". The file is `docs/verification/YYYY-MM-DD-<slug>.md`, and `Scripts/docs-index.sh --check` must pass. Nothing is added to this page.
