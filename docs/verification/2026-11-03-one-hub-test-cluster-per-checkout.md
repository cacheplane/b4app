## 2026-11-03: One hub test cluster per checkout

`Hub/scripts/test-db.sh` used to give every checkout on the Mac one shared cluster on port 54329. That caused the environmental failures in the next entry: another worktree's `--stop` ended runs mid-test, and two runs of the same `#[sqlx::test]` dropped each other's database. Now each checkout has its own cluster. The data is in `$TMPDIR/b4hub-test-<checksum of the checkout path>`, on a port from the same checksum (54400 to 55399), recorded in the data directory. A port held by something else moves the cluster to the next free one. CI is unchanged; its `hub` job uses a PostgreSQL service container.

- **A second checkout** (a scratch copy of the script) got its own cluster. Its recorded port was seeded with this checkout's port, and it moved to the next one. Its `--stop` left this checkout's cluster running.
- **Two `cargo test --workspace --locked` runs at once**, one against each cluster, both passed. On one shared cluster, the same tests would have dropped each other's databases.
- `shellcheck` is clean.
- A shared cluster started by the old script keeps running until it is stopped. `pg_ctl -D "$TMPDIR/b4hub-test/data" stop` stops it.

Also in this PR: **`AccountCommandTests.logoutIsBoundedWhenTheRuntimeAndTheHubIgnoreCancellation`** failed on a loaded runner (CI run 41717884580). It took 5.43 s against a bound of `short.total` (4.3 s) + 1 s. That test and `logoutBoundedWhenHubDown` now allow 3 s of slack (`logoutSlack`). A regression still fails: `work` or `push` at its standard 9.5 s adds at least 7.5 s, and a step without a bound never ends. The 1 s slack never caught `close` or the floor at their standard values either (they add 0.5 s and 0.2 s). Both tests passed 5 runs locally.
