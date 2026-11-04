## 2026-11-04: Rolling deploys on two tasks after D-172, live

Rerun of the two-task live check ("The test hub on two tasks, live", below) once D-172 (#103, `d0a7116`) reached `hub.test.b4.run` (task definition 30). The same script and the same throwaway `livecheck` user were used, with three fresh codes minted through `admin-shell.sh test hub` and never printed. **22 of 22 passed**:

- Everything that passed before passed again: routing and `409 relocated`; long-poll wake-ups across instances (1.21 to 1.25 s, of which 1 s is the script's own delay); `refresh` and named watch refusals; and log-out and revocation through the other instance (4001, 0.28 s and 0.50 s).
- **A forced rolling deploy.** The load balancer cut both links with no close code, as before. The iPhone relinked to a new task in 0.26 s (one attempt), and the Mac in 0.85 s (three attempts: two `409 relocated` while a sibling's claim moved, then served). Before D-172 the figures were 16.8 s and 25.0 s. Both ended on the same new instance.
- **Another Mac on the test hub (`01a19ee2…`) shows the same thing in the hub's logs.** Through #103's own rollout (01:15 UTC), whose old tasks still ran the code without D-172, it was cut, refused `relocated` seven times, and relinked after SIGTERM: 22 s offline. Through the forced deploy on the new code (01:20 UTC) it was cut at 01:20:13.006 and relinked at 01:20:13.651, 0.65 s later, while SIGTERM came at 01:20:32.
- The `livecheck` devices are revoked again; the org and user remain.
