## 2026-11-09: Hosted hubs, week-one review

A reassessment of both hosted hubs one week after they went live (continuation of [the hosted-hub gates](2026-11-02-hosted-hubs.md)). Checks ran against the real accounts with the owner's `aws login` session; nothing below is from a fixture.

| Check | Result |
| --- | --- |
| `hub.b4.run` and `hub.test.b4.run` `/readyz` | both `ok`, migrations current, relay probe ok; two tasks each |
| Terraform drift (`terraform plan` from `main`, both roots) | test: no changes; prod: only the two resources PR #153 was about to add, applied the same day through the new plan-gated `production` approval (run 42708863347, 2 added, 1 changed) |
| Nightly backups and copies since the copy-vault key (D-181) | copies completed every night into `b4hub-prod-copy` under `alias/b4hub-prod-copy`, except 2026-11-08 06:00 UTC, when the backup job itself failed in both accounts: "could not start because it is either inside or too close to the weekly maintenance window" (RDS maintenance `sun:06:30-07:30`, plan at 06:00). Fixed by D-196 (window moved to `sun:09:00`); PR #155 |
| Alarms in ALARM | `latency-p99` in both accounts, continuously since 2026-11-08 02:51 PST and flapping before that: the ALB p99 is the 25 s sync long-poll. Fixed by D-196 (latency from the hub's request log, long polls excluded); PR #155. No other alarm active |
| Production approval queue | two `apply-prod` runs from runbook-only merges (11-05, 11-06) had been waiting for days for a no-op; cancelled. D-194 (PR #153) excludes `Infra/README.md` from the workflow and gates the approval on a non-empty read-only plan; its own run was the first to pass through the gate with a real change |
| Backup copy failure alerting | none existed (the 2026-11-03 failure was found by hand); D-194 adds the EventBridge rule, applied to production 2026-11-09 |
| Organization region policy, `us-west-2` exception | narrowed from `rds:*` and `ec2:*` to listed actions (D-196); copy vault, subnet groups and VPC calls still answer, `rds describe-db-clusters` is denied |
| Sign-up policy | `B4HUB_SIGNUP=open` on both hubs; the owner confirmed open sign-up on production is intended (2026-11-09) |

D-196 applied the same day: test by the merge of PR #155, production through the plan-gated approval (run 42718358851, 1 added, 2 changed). Afterwards `latency-p99` reads OK in both accounts on `RequestLatencyMs` (test p99 about 20 ms), no alarm is in ALARM in production, both instances show maintenance `sun:09:00-sun:10:00`, and `hub.b4.run/readyz` is ok. The first Sunday backup under the new window (2026-11-15 06:00 UTC) is the remaining proof.

D-198 (a backup job that fails, is aborted, or expires unstarted emails the alerts topic; PR #164) was applied on 2026-11-10: test by the merge, production through the plan-gated approval (run 42779638901, 2 added, 1 changed, as planned), and `hub.b4.run/readyz` answered 200 afterwards. The rule was not inspected in either account directly (the operator's CLI session had expired) and no failed job has exercised it.

Not re-run: the restore drill (last 2026-11-04), gate 2b, Compose and Helm gates. Still deferred by the owner: external monitoring (D-186).
