# M4: managed B4 execution and the shared CLI (design)

Date: 2026-10-31. Spec: `docs/roadmaps/Personal_Agent_Workspace_Technical_Spec_and_Roadmap.md` sections 3.1, 5.1, 9.1, 9.4, 9.5, 10.3, 11, and the M4 checklist. Builds on M3: the same `B4Adapter`, `SessionService`, protocol envelope, CLI, and SwiftUI surfaces, plus a coordinator-owned server supervisor and a registry of local projects.

## Intent

The owner registers a local B4 project once, and from then on the app (or the CLI) starts, stops, restarts, and watches that project's server without a separate terminal. Route connections on the managed server are ordinary B4 connections that the existing adapter already speaks to; the only difference is that the coordinator knows the server's process and port. GUI and CLI see one coordinator, one owned registration per project, and the same status and logs. The coordinator never kills a process it did not verifiably start, and an attached server (M3) is never touched.

## Verified facts this design rests on

Read from `github.com/cacheplane/b4run` at `origin/main` (`844cf3bf`, `@b4run/cli` 0.15.8) and the live run of 2026-10-31 recorded in `docs/research/2026-10-30-b4-runtime.md`.

- `b4 routes [--cwd PATH] [--json]` prints `RouteManifest { appRoot, routes: [{ id, pathname, kind, entryFile, routeDir, segments }] }` on stdout. Discovery imports `b4.config.ts` and every route module, so inspecting a project executes its code. The protocol route key is `${id}#${kind}`.
- `b4 dev [--port N] [--env-file PATH]` takes no `--cwd`; the app root is found from the working directory. It loads the env file (`--env-file`, then `b4.config.ts` `env`, then `<appRoot>/.env`) into its own environment, runs typegen, spawns the runtime as a child with `stdio: ["ignore", "pipe", "pipe", "ipc"]`, binds `127.0.0.1`, waits on `GET /healthz` → `{ status: "ready" }`, prints `B4.run dev ready at http://127.0.0.1:<port>`, watches the app directory, and restarts the child on changes. On SIGTERM or SIGINT it closes the session: SIGTERM to the child, SIGKILL after one second, then exits.
- `b4 start [--host H] [--port N]` takes no `--cwd` and no `--env-file`, loads no `.env`, runs no typegen, defaults the host to `HOST` then `0.0.0.0` and the port to `PORT` then `8000`, serves source in-process, prints `b4 start listening on <url>`, and exits on SIGTERM or SIGINT.
- `b4 typegen [--cwd PATH]` writes `.b4/b4.generated.d.ts`; it is a type-level artifact that the runtime does not need.
- The package is `"type": "module"` with bin `b4` at `node_modules/@b4run/cli/dist/index.js`, `engines.node >= 24`. pnpm's `node_modules/.bin/b4` is a shell shim that resolves `node` from `PATH`, which a Finder-launched app does not have, so the coordinator runs the entry file with an explicit Node.
- Node runtime stores default to `<appRoot>/.b4/{threads,checkpoints}.sqlite` and survive restarts (live-verified in M3).
- On this Mac: Node v24.20.0 at `~/.nvm/versions/node/v24.20.0/bin/node`; no `b4` on `PATH`; the M3 live project was a scratch directory with `@b4run/cli` 0.15.8 installed, one `/chat#agent` route on `gpt-5-mini`, and `OPENAI_API_KEY` in this repository's gitignored `.env`; `~/repos/hashbrown/tools/{lifecycle,marketing}` are 0.14.0 projects with only `workflow` routes behind a service bearer and Neon Postgres; `~/repos/b4run/examples/chat/server` on the local checkout is a pre-rename `@dawn-ai/cli` project.

## Architecture

```
Router ──▶ LocalServerService (actor)        ──▶ ManagedProcess (posix_spawn, own process group,
             ├─ registry: LocalServer rows        stdout+stderr → log file, identity captured)
             ├─ inspector: `b4 routes --json`  ──▶ CommandRunner (one-shot, bounded, timeout)
             ├─ readiness + health monitor     ──▶ B4HTTPClient.health()
             └─ logs: redacted tail of the file
SessionService ──▶ B4Adapter (unchanged) for route connections; asks LocalServerService
                   whether a managed server is ready before any adapter call
```

### Registry: `LocalServer`

One row per canonical project path (the existing `localServers` table, migration `v2` adds columns). Fields: `id`, `name` (unique, CLI handle, default the directory name), `projectPath` (resolved, absolute, unique), `nodePath`, `cliPath` (the resolved `dist/index.js`), `cliVersion` (read from `node_modules/@b4run/cli/package.json`, never by running the CLI), `launchMode` (`development` or `source`), `envFilePath?`, `requestedPort` (always set: given, or allocated once at registration so route connections keep a stable origin), `actualPort?`, `generation`, `pid?`, `processStartedAt?` (seconds since the epoch, from `kinfo_proc`), `ownershipVerified`, `health` (`stopped | starting | ready | unhealthy | unknown`), `statusMessage?`, `routes` (JSON array of `{ id, kind, entryFile }` from the last inspection), `logPath`, timestamps.

A registration is a launch profile. `server add` on a path that already has a row returns the row when the profile (mode, env file, port) matches; updates the mode and env file when the server is stopped; refuses with `owned_process_conflict` while an instance is running (spec 9.5). The port never changes once a route connection references the server (`protocol_invalid`, "register a new project directory or remove the connections first"), because managed connections carry `http://127.0.0.1:<port>` as their target and threads use that origin as their native scope; before any connection exists a stopped registration may take a new `--port`.

### Trust and inspection

`server add <dir>` resolves the directory, requires `package.json` and `b4.config.*` (the app root), resolves Node (`NodeLocator`, `B4APP_NODE_PATH` honored) and the project-installed CLI (`<dir>/node_modules/@b4run/cli/dist/index.js`; nothing is downloaded), reads the CLI version from its `package.json` and refuses below 0.15.7, then runs `node <cli> routes --json --cwd <dir>` with the working directory set to the project, a 60 s timeout, and the child environment described below. The manifest is stored as `routes`. Registration is the trust decision: the CLI help and the GUI form both say that inspecting and running a project executes its configuration and modules.

`server inspect` re-runs the same discovery on demand; it is not run automatically on start.

### Child environment

The coordinator never inherits its own environment into a server. The child environment is: `PATH` = the Node executable's directory plus `/usr/bin:/bin:/usr/sbin:/sbin`; `HOME`, `TMPDIR`, `LANG`, `USER`, `SHELL` from the coordinator; `NODE_ENV` left unset; plus, when `envFilePath` is set, the pairs parsed from that file with a dotenv parser that does no shell evaluation (`KEY=value`, optional `export`, single and double quotes, `#` comments, `\n` escapes inside double quotes). Parsed values exist only in the spawn call; they are never stored, logged, or returned.

- `envFilePath` defaults to `<project>/.env` when that file exists and no `--env-file` is given, so the default profile behaves like a plain `b4 dev` for a project that keeps its model key beside its code; `--env-file <path>` overrides it; a path that does not exist is refused at registration. The resolved absolute path is what the row stores.
- Development mode passes `--env-file <path>` too, so `b4 dev` applies the same file itself and hot reload keeps it.
- Source mode passes `--host 127.0.0.1 --port <port>` explicitly and sets nothing else, so `b4 start` never binds `0.0.0.0` and never reads a `.env` on its own. Typegen is not run before `b4 start` (the generated file is types only); `server inspect` and `b4 dev` keep it fresh.

### Launch, readiness, and ownership

`server.start`, `server.restart`, `server.add`, and `server.inspect` block until readiness or inspection has finished (or failed), so one request carries the outcome and its exit code; clients send them with a 150 s timeout. The GUI shows `starting` from the `server.changed` event while the request is in flight. A second `start` for a server that is already `starting` joins the in-flight start and returns its outcome rather than spawning again or reporting a conflict against the coordinator's own child.

`server start` is idempotent: a `ready` server returns its row. Otherwise:

1. Port check. The coordinator tries to bind `127.0.0.1:<requestedPort>` and releases it. A failure is `owned_process_conflict` ("port 3101 is in use; nothing was stopped"). It never probes `/healthz` to claim a listener, and it never signals a process it did not spawn.
2. Spawn with `posix_spawn`: `[nodePath, cliPath, "dev", "--port", port, "--env-file", envFile]` or `[nodePath, cliPath, "start", "--host", "127.0.0.1", "--port", port]`, working directory = project path, own process group (`POSIX_SPAWN_SETPGROUP`), stdin `/dev/null`, stdout and stderr appended to the log file. `generation` increments, `pid` and `processStartedAt` (read back through `sysctl KERN_PROC_PID` immediately after the spawn) are stored, `health = starting`.
3. Readiness: poll `GET /healthz` every 250 ms until `{ status: "ready" }` or 90 s; the child exiting first is a failure with its exit status and the last log lines. Success stores `actualPort`, `ownershipVerified = true`, `health = ready`.
4. Monitor: a task per running server checks the process every second (`waitpid(WNOHANG)` for a child of this coordinator, `kill(pid, 0)` plus the identity check for an adopted one) and `/healthz` every 10 s; three consecutive failures mark `unhealthy`; an exit marks `stopped` with the status. Every change publishes `server.changed` and a `connection.changed` for each route connection (`ready` when the server is ready, `offline` otherwise).

Verified identity is `(pid, processStartedAt within one second, argv contains cliPath and the port)`, read from `KERN_PROC_PID` and `KERN_PROCARGS2`. Ownership is never inferred from a pid or an open port alone.

### Stop and restart

`server stop` sends SIGTERM to the process group of a verified owned instance, waits up to 10 s, then SIGKILL to the group, then confirms the port is free. `b4 dev` forwards the signal to its runtime child itself; the group kill covers a runtime child that outlives a killed parent. If the identity check fails, nothing is signalled and the row becomes `stopped` with `ownershipVerified = false` and a message naming the pid that was left alone. `server restart` is stop then start, keeping the generation sequence. `.b4/` is untouched by any of this.

Stopping a server ends any in-memory run on it: a running turn on one of its route connections becomes `reconciling` and is later reported as failed, while a parked prompt survives in `.b4` and is re-opened on the next start. So `server.stop` and `server.restart` refuse with `owned_process_conflict` (details `reason: turn_active`, the thread ids) while a route connection has a turn in `submitting`, `running`, or `stopping`, unless `force: true`; the CLI passes `--force`, and the GUI asks "Stop while a turn is running?" and re-sends with force on confirmation. A parked (`waiting_for_user`) turn does not block.

### Coordinator start and re-adoption

Managed servers are meant to outlive the coordinator (a coordinator crash or an app Quit must not lose a server that is mid-run). On start, every row with a `pid` is checked: identity verified and `/healthz` ready → adopted (`ownershipVerified = true`, monitor started); identity verified but not ready → `unhealthy`; identity mismatch or no process → `stopped`, `pid` cleared, message "pid N is not the server started on …; left untouched". A row whose ownership is unresolved is never auto-started.

Quit of the macOS app leaves managed servers running (the app's in-process coordinator stops; the servers persist and are re-adopted on the next launch). The keep-running versus stop-and-quit choice of spec 10.3 is M5.

### Logs

Stdout and stderr go to `<dataDir>/logs/servers/<name>.log` (0600) opened `O_APPEND`, so a coordinator restart loses nothing and the child needs no pipe. `server logs` reads the tail (default 200 lines, `--lines N`) through `LogRedactor`: `Bearer <x>` → `Bearer [redacted]`, `sk-…`/`sk-proj-…` and similar provider key shapes, and `key|token|secret|password|authorization[=:] value` pairs are masked before the text leaves the coordinator. The file is bounded at 4 MiB by copy-truncate (keep the last 1 MiB; `O_APPEND` writers continue correctly after `ftruncate`). `--follow` and the GUI log panel poll `server.logs` with the last byte offset; log lines are never events, so they cannot evict conversation events from the replay buffer.

### Route connections

`connection add --kind b4 --server <name> --route /chat#agent` (GUI: a "Connect" button beside each inspected route) creates a `Connection` with `b4Mode = managed_local`, `localServerId`, `target = http://127.0.0.1:<requestedPort>`, `routeKey`, no credential. The adapter is the unchanged `B4Adapter`. `SessionService` consults `LocalServerService` before `inspectConnection`, `createSession`, `sendTurn`, and `loadSession` on a managed connection: a server that is not `ready` yields `endpoint_unavailable` with "Server research is stopped. Run `agent-workspace server start research`." Reconciliation, interruption, and `respond` go through unchanged (they fail honestly on a stopped server, exactly like an attached one that went away). A route whose kind is not `agent` is still accepted and stored `incompatible` (D-023). Removing a server registration is not in scope; `connections.localServerId` already nulls on delete for when it arrives.

### Protocol, CLI, GUI

Methods (all mutations except `list`, `status`, `logs`): `server.add { projectPath, name?, launchMode?, envFilePath?, port? }`, `server.list`, `server.start { serverId }`, `server.status { serverId }` (reads the row and the live monitor state), `server.logs { serverId, lines?, afterOffset? }`, `server.restart { serverId, force? }`, `server.stop { serverId, force? }`, `server.inspect`. `ConnectionAdd.Params` gains `serverId`. New event kind `server.changed` carrying the row. `DiagnosticsRead` lists managed servers under their own rows.

CLI (`Sources/AgentWorkspaceCLI/ServerCommands.swift`): `server add <dir> [--name] [--mode development|source] [--env-file] [--port]`, `server list`, `server start|status|inspect <name>`, `server stop|restart <name> [--force]`, `server logs <name> [--lines N] [--follow]`; `--json` everywhere; exit 0 on success, 2 when a start or inspect ends with the server not ready, 4 for invalid input, 1 otherwise (`owned_process_conflict` maps to 1 with the code in the JSON). `connection add --kind b4 --server <name> --route <key>`.

GUI (`Sources/WorkspaceUI/LocalServersView.swift`): a list of registrations (name, project path, mode, port, health badge, pid when running, status message), Start / Stop / Restart / Inspect buttons, the inspected routes with a Connect button each (existing connections for that route show as "Connected"), a log panel that polls while visible, and an "Add project" form (directory field with Choose…, name, mode picker defaulting to source, env file path, port) whose caption states that inspection executes the project's config and modules. `WorkspaceModel` gains `servers`, `serverLogs`, and the server actions; the Connections screen's B4 card points to Local servers for managed projects.

### Decisions

- **D-024** Managed servers are spawned with `posix_spawn` into their own process group with stdout and stderr redirected to a per-server log file, not through `StreamingProcess`. The pipe-based helper would tie the server's life to the coordinator (an orphaned Node process dies on its next write to a closed pipe) and would lose logs across a coordinator restart; the file keeps the server independent and the group lets stop reach a runtime child that outlived `b4 dev`.
- **D-025** Ownership is `(pid, process start time, argv contains the CLI entry and the port)` from `KERN_PROC_PID` and `KERN_PROCARGS2`, captured at spawn and re-verified before every signal and on every coordinator start. A pid or a listening port alone never establishes ownership, and a mismatch leaves the process alone and marks the registration stopped.
- **D-026** The project-installed CLI is run as `<node> <project>/node_modules/@b4run/cli/dist/index.js`, never through `node_modules/.bin/b4` or a shell, and never downloaded; the version comes from the package's `package.json`.
- **D-027** A registration allocates its port once (or takes `--port`) and keeps it, so route connections have a stable origin; a start whose port is taken fails with `owned_process_conflict` and stops nothing.
- **D-028** Source mode (`b4 start --host 127.0.0.1 --port N` with a coordinator-built environment parsed from the env file without shell evaluation) is the default; development mode (`b4 dev --port N --env-file P`) is explicit because hot reload can replace the runtime mid-turn.
- **D-030** `server stop` and `server restart` refuse while a route connection has a running turn unless forced, because stopping loses the in-memory run; a parked prompt is durable in `.b4` and does not block. The M5 Quit dialog builds on the same check.
- **D-029** Server logs are files the child writes directly; the coordinator serves redacted tails on request and bounds the file by copy-truncate. Log lines are never published as events.

## Non-goals

Removing registrations, the Quit choice dialog (M5), built artifacts (`b4 build` + `node .b4/build/server.mjs`), running `b4 typegen` before `b4 start`, auto-starting a server when a thread needs it, LaunchAgent supervision (M6), multiple instances per project, custom hosts, remote projects, reading or editing env files from the GUI, log search.

## Tests

- Fixture: `Tests/B4AdapterTests/Fixtures/fake-node.sh` (answers `--version` with `v24.0.0`, otherwise executes its first argument with `python3`) and `Tests/B4AdapterTests/Fixtures/fake-b4-cli.py` (a `b4` stand-in: `routes --json --cwd` reads `src/app/*/index.ts` and prints a manifest with the kind taken from the export; `dev --port --env-file` prints the loaded-variables line and `B4.run dev ready at …`, then serves the protocol by importing `fake-b4.py`; `start --host --port` refuses to bind without `--host`, serves the same; both ignore SIGTERM for `FAKE_B4_HANG_ON_TERM` seconds when set, and `dev` spawns a grandchild runtime when `FAKE_B4_GRANDCHILD=1` so the group kill is exercised; `typegen` exits 0). Tests build a scratch project with `package.json`, `b4.config.ts`, two routes (`agent`, `workflow`), and `node_modules/@b4run/cli/{package.json,dist/index.js}` where `index.js` is a copy of the fake CLI.
- `WorkspacePlatform`: dotenv parsing (quotes, comments, escapes, no expansion), `ProcessIdentity` of the current process and of a spawned child, `ManagedProcess` spawn with redirected output and group termination, `LogRedactor` cases, port probing.
- `LocalServerService` over the coordinator socket: add with inspection (routes, version, refusal of a project without the CLI, refusal of an old version), start to ready in both modes, idempotent start, status, logs tail and offset follow, restart keeps the generation sequence, stop frees the port, port conflict reported without a kill (a foreign listener survives), stale pid on coordinator restart left alone, live child re-adopted after a coordinator restart (identity verified), exit detected by the monitor, route connection added and a thread conversed through the managed server, connection refused while the server is stopped, same project re-added returns the same row, conflicting profile refused while running, env file values reach the child (the fake prints a marker from `FAKE_B4_MARK`) without appearing in any result or log output.
- Live, on the target Mac: the real `@b4run/cli` 0.15.8 project chosen by the owner, both modes, GUI start → CLI status/logs/stop and CLI start → GUI inspect/stop, `.b4` preserved across restart, a conversation through the route connection. Never in CI.
