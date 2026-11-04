## 2026-11-03: The test hub on two tasks, live

`hub.test.b4.run` now runs two tasks: `envs/test/main.tf` sets `task_count = 2` and `desired_count = 2`. The change was applied by hand with the owner's `b4hub-test` profile; the plan held only the four expected changes (rolling deploy 100/200, deregistration delay 5 s, application-cookie stickiness on). The service was then scaled with `update-service`. The image ran D-161 to D-168 (task definitions 27, then 28).

A script drove three devices of a throwaway `livecheck` org and user (seeded and enrolled through `admin-shell.sh test hub`; codes and tokens never printed). It pinned each request to one instance with that instance's load-balancer cookies, collected from `/readyz`. 20 of 22 checks passed:

- **Routing (D-085).** Both instances answer `/readyz`, and a request carrying one instance's cookies always reaches it. The Mac's link claimed the user. The phone's link, sent to the other instance, got `409 relocated` naming the owner, and the retry on the owner was served. The iPad joined the same instance.
- **Long-poll wake-ups (D-161).** A push on one instance woke a 20 s long-poll on the other in 1.22 to 1.23 s (1 s of which was the script's own delay before pushing), six times, three each way.
- **Watching (D-167, D-168).** The Mac was told the watched thread. A second watcher reached it as `refresh: ["lc-thread"]`. A refused watch came back `not_found` with `details.threadId`.
- **Sessions (D-162).** A log-out sent to the other instance closed the iPad's link with 4001 in 0.28 s. A revocation sent to the other instance closed the Mac's link with 4001 in 0.29 s, and the phone heard it go offline.
- **The listener (D-164).** No "heard nothing" or listener warning was logged in the 30 minutes covering the test and two deploys.

**Failed: a rolling deploy kept devices offline for 17 to 35 s.** After `--force-new-deployment` both links came back on the same new task, but the phone was offline 16.8 s and the Mac 25.0 s. Another Mac linked to the test hub (`01a19ee2…`) was offline 35 s, and about 30 s in the deploy before. The hub's logs show why:

- The load balancer cut every link of the old tasks at the end of the deregistration delay. The links closed with no close code, not the hub's 1001.
- ECS sent SIGTERM about 16 s later: links cut at 23:43:27–28, SIGTERM at 23:43:43–44. The earlier deploy was the same: cut at 23:38:57, SIGTERM at 23:39:15–16.
- In between, the old tasks were alive and heartbeating, so they kept their users' claims. Every reconnect to a new task was refused `409 relocated`, and the devices' backoff stretched the wait.
- Runbook 13's "after `deregistration_delay` ECS sends SIGTERM" does not hold as written, and D-165's per-user release never ran, because the links ended before shutdown began.

**Open:** a hub change so that an instance gives up a user's claim once that user has no link on it, so a deploy (or any cut) does not strand reconnects behind a live owner. The test hub stays on two tasks. The `livecheck` devices are revoked (the iPad's token was deleted by its log-out). The org and user remain, for the next run.
