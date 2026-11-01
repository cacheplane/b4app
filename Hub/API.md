# Hub HTTP API

The hub speaks JSON over HTTP. This document describes what the code in `crates/b4hub` does;
where the two disagree, the code is right and this file is the bug.

All paths are relative to the hub's base URL (`http://localhost:8080` for the Compose stack, which publishes the port on `127.0.0.1` only).
Clients refuse any non-HTTPS URL whose host is not `localhost`, `127.0.0.1`, or `::1`.

## Conventions

### Authentication

Every route except `/healthz`, `/readyz`, and `POST /v1/enroll` requires

```
Authorization: Bearer <device token>
```

The scheme is matched case-insensitively; the token must be non-empty and contain no whitespace.
The token comes from `POST /v1/enroll`, which is the only place it is ever shown; the hub stores
only its SHA-256. Authentication happens before the request body is read, so an unauthenticated
request is refused without its body being consumed. A missing header, another scheme, a malformed
token, an unknown token, and a revoked device all answer the same `401 unauthorized`, so a caller
learns nothing about which it was.

The principal (org, user, device) comes only from the verified token. Nothing in a request body or
query can name a different one, and the wire `Change` carries no device id: the hub attributes
every change to the authenticated device.

### Errors

Every error uses B4's envelope:

```json
{"error": {"kind": "request_error", "message": "not found", "details": {"code": "not_found"}}}
```

`kind` is `request_error` (the caller asked for something wrong or not available to it) or
`execution_error` (the hub could not do what was asked). `details.code` is the stable,
machine-readable part; `message` is fixed human-readable text and may change. Messages never
contain SQL, panic text, or another tenant's data. A missing resource and an inaccessible one
answer the same generic `404 not_found`.

| HTTP | `details.code` | `kind` | When |
| --- | --- | --- | --- |
| 400 | `invalid_request` | request | The body is not valid JSON for the endpoint (malformed JSON, an unknown or missing field, a wrong value type, a missing or wrong `Content-Type`); a `deviceName` or `platform` that fails validation; a push with more than 1000 changes; a non-numeric `after`, `limit`, or `wait`. |
| 401 | `unauthorized` | request | The bearer token is missing, malformed, unknown, or belongs to a revoked device. |
| 401 | `invalid_code` | request | The enrollment code is wrong, expired, or already used (the three are indistinguishable). |
| 404 | `not_found` | request | No such route, or a resource that does not exist or is not yours. |
| 405 | `method_not_allowed` | request | The route exists but not for that method. |
| 410 | `resync_required` | request | The pull cursor is older than the retention horizon: the hub has pruned the changes after it. Restore from `GET /v1/snapshot` (see *Horizon*). |
| 413 | `payload_too_large` | request | A push body over 32 MiB. (A change whose `value` is over 2 MiB is rejected per change instead; see `POST /v1/changes`.) |
| 500 | `internal_error` | execution | Any unexpected failure; the cause is logged on the hub, never sent. |
| 503 | `not_ready` | execution | `/readyz`: the database is unreachable or migrations are pending. |
| 503 | `shutting_down` | execution | `/readyz` after SIGTERM. |

### Limits

| Limit | Value | Applies to |
| --- | --- | --- |
| Change `value` | 2 MiB (2,097,152 bytes of its serialised JSON) | each change in a push; over it, that change is rejected (`rejected: [{deviceSeq, code: "payload_too_large"}]`) and not stored, and the rest of the batch lands |
| Push body | 32 MiB | `POST /v1/changes`; over it, `413 payload_too_large` |
| `MAX_PUSH_CHANGES` | 1000 changes | one push; over it, `400 invalid_request` |
| Pull page | 1000 changes (`limit` is clamped to 1 to 1000; default 1000), and 8 MiB (8,388,608 bytes) of serialised `value` JSON summed over the page; whichever comes first, and always at least one change | `GET /v1/changes` |
| Retention | `B4HUB_RETENTION_DAYS`, default 30 | how long the hub keeps the change log (see *Horizon*) |
| Long-poll `wait` | 25 seconds | `GET /v1/changes`; a larger `wait` is clamped to 25 |
| Other request bodies | 2 MiB (axum's default) | `POST /v1/enroll` |

The Mac client sends batches of 500 and replaces a `displayItems.payload` over 1 MiB with
`{"truncated": true, "bytes": n}` before upload, so the hub's 2 MiB limit only ever rejects a
broken or hostile client's change. The hub rejects; it never truncates.

### Protocol version

`GET /readyz` reports `minClientProtocol` (currently `1`), the oldest client protocol this hub
speaks. A client whose own protocol is older than that must refuse the hub.

## Routes

### `GET /healthz`

Liveness. No authentication. Always `200`:

```json
{"ok": true}
```

### `GET /readyz`

Readiness: the database answers and every migration is applied. No authentication. This is what
the container `HEALTHCHECK` calls.

`200`:

```json
{"ok": true, "migrations": "current", "minClientProtocol": 1}
```

`503 not_ready` when the database is unavailable or migrations are pending; `503 shutting_down`
once SIGTERM has been received (see "Shutdown").

### `POST /v1/enroll`

Exchange a one-time enrollment code for a device token. No `Authorization` header: the code is
the credential. The operator mints a code with `b4hub enroll --user <username>`; it is eight
characters from `BCDFGHJKLMNPQRSTVWXZ23456789`, valid for ten minutes, single-use, and matched
case-insensitively.

Request (all three fields required, no others allowed):

```json
{"code": "ABCD2345", "deviceName": "Brian's MacBook Pro", "platform": "macos"}
```

- `deviceName`: 1 to 200 characters after trimming.
- `platform`: `macos`, `ios`, or `cli`.

Both are validated before the code is redeemed, so a malformed request does not use the code up.

`200`:

```json
{
  "deviceId": "0198...",
  "token": "<43 characters, base64url>",
  "org": {"slug": "cacheplane", "name": "cacheplane"},
  "user": {"username": "blove", "displayName": "Brian Love"}
}
```

`token` appears in this response and nowhere else; keep it in the Keychain. Errors: `400
invalid_request`, `401 invalid_code`.

### `GET /v1/me`

The authenticated device and the org and user it belongs to. `200`:

```json
{
  "deviceId": "0198...",
  "deviceName": "Brian's MacBook Pro",
  "platform": "macos",
  "org": {"slug": "cacheplane", "name": "cacheplane"},
  "user": {"username": "blove", "displayName": "Brian Love"},
  "createdAt": "2026-10-31T12:00:00.000000Z"
}
```

`createdAt` is RFC 3339 in UTC with microseconds. Errors: `401 unauthorized`.

### `GET /v1/devices`

The authenticated user's devices (every device of that user in the org, the calling one and
revoked ones included), oldest enrolled first. Another user's devices never appear. `200`:

```json
{"devices": [
  {"id": "0198...", "name": "Brian's MacBook Pro", "platform": "macos",
   "lastSeenAt": "2026-10-31T12:00:00.000000Z", "revokedAt": null},
  {"id": "0199...", "name": "iPhone", "platform": "ios", "lastSeenAt": null,
   "revokedAt": "2026-10-31T13:00:00.000000Z"}
]}
```

`lastSeenAt` and `revokedAt` are RFC 3339 in UTC with microseconds, or `null` (never seen; not
revoked). `lastSeenAt` is written at most once a minute per device. Errors: `401 unauthorized`.

### `DELETE /v1/devices/self`

Revoke the calling device: its token rows are deleted and `devices.revoked_at` is set. Changes the
device already uploaded stay in the feed. `204` with no body. The token stops working
immediately; the next request with it is `401 unauthorized`. Errors: `401 unauthorized`.

### `POST /v1/changes`

Upload a batch of changes recorded on this device.

Request (`changes` required, no other field allowed):

```json
{"changes": [ <Change>, ... ]}
```

`200`:

```json
{"acceptedThrough": 12}
```

or, when the hub refused some changes:

```json
{"acceptedThrough": 12, "rejected": [{"deviceSeq": 7, "code": "column_not_writable"}]}
```

`acceptedThrough` is the highest `deviceSeq` in the batch. For an empty batch it is the highest
`deviceSeq` the hub has recorded for this device, or `0`; a rejected change is not recorded, so
that can sit below a `deviceSeq` the device had rejected earlier. A client marks local rows
`synced` only once `acceptedThrough` covers them. In a non-empty batch it covers rejected changes
too: a rejection is final, so the client must not resend them. `rejected` is omitted when empty,
so a client that predates it decodes the response unchanged. `code` is one of:

- `column_not_writable`: the device is an `ios` or `cli` device and the change is not one of the
  phone's (see *Clocks and the write rule* below).
- `payload_too_large`: the change's `value` is over 2 MiB. Only that change is rejected; the rest
  of the batch lands.
- `invalid_clock`: the change's `hlc` is present but not in the clock form. Only that change is
  rejected; a change with no `hlc` is fine.

A rejected change is not recorded in the feed and not applied, so no other device ever sees it.

**Idempotency is per device.** A change is identified by `(device, deviceSeq)`. One the hub
already holds counts as accepted and is not recorded or applied again, so retrying a batch (after
a timeout, or after a crash between the response and the client's bookkeeping) is harmless.
`deviceSeq` must be unique per device and increasing.

**Recording and applying.** The batch runs in one transaction. Each new change is recorded in the
org's feed and applied to the mirrored tables with the same semantics as the Mac's replay: an
`insert` upserts the columns it carries, an `update` sets one column, a `delete` deletes. A change
that cannot apply (an unknown table, a missing parent row, a malformed shape, a value the column
type refuses) is still recorded, so every device's feed stays complete, but it is skipped and
counted in the hub's log; the push still succeeds and `acceptedThrough` still covers it. Mirrored
rows are keyed to the pushing user as well as the org, so another user of the org pushing the same
row id cannot overwrite, update, delete, or adopt as a parent the first user's row.

**Refusals**, before anything is stored: `401 unauthorized`; `400 invalid_request` for a body that
is not `{"changes": [...]}` or has more than 1000 changes; `413 payload_too_large` for a body over 32 MiB. (A single change
whose `value` is over 2 MiB is no longer a 413: it is a per-change `rejected` entry.) Pushes to
one org are serialised, so commit order is `hubSeq` order.

**Clocks and the write rule.** Every change may carry an `hlc`, a hybrid logical clock written
`<12 lowercase hex digits of epoch milliseconds>-<4 hex digits of counter>-<device id>` (for
example `0192e0f1a2b3-0000-01a194cf-0d12-7418-b3b5-5559dbee2441`). Clocks compare as plain
strings. A change with no `hlc` (an M8a client) is stamped with its `wall`, counter `0000`, and
the pushing device's id. A clock more than 300 000 ms (five minutes) ahead of the hub's wall
clock is rewritten to the hub's milliseconds with counter `0000` and the same device id, so a
device with a fast clock cannot win every later conflict; exactly 300 000 ms ahead is kept. The
clock the hub keeps is the one it serves back in the feed.

These columns merge last-writer-wins: `threads.title`, `threads.pinned`, `threads.archived`,
`threads.readTurnId`, `threads.projectId`, `projects.name`, `drafts.threadId`, `drafts.text`,
`drafts.updatedAt`. The hub remembers, per row and column, the clock of the change that last set
it (`column_clocks`); an `update` of such a column applies only when its clock is greater, and
an `insert` counts as setting every such column it carries, at its clock. A change that loses is
still recorded in the feed (it is history) but writes nothing. Every other column applies
whatever its clock, as in M8a.

A `macos` device may write any column. An `ios` or `cli` device may only `update` these
columns, and `insert` rows of `drafts`: `threads.title`, `threads.pinned`, `threads.archived`,
`threads.readTurnId`, `projects.name`, `drafts.threadId`, `drafts.text`, `drafts.updatedAt`.
Anything else (including every `delete`) is rejected with `column_not_writable`. A draft is
cleared by setting `text` to `""`, never by deleting it.

**Ownership and scrubbing.** Each mirrored row records `owner_device_id`, the device of its latest
`insert` (an `update` never changes it; `device_id` remains the last writer). The hub sets
`connections.authReference`, `connections.localServerId`, and `connections.target` to NULL on
every insert and update, whatever the change carries.

### `GET /v1/changes`

The change feed: this user's changes (from every one of the user's devices, including the calling
one) with `hubSeq` greater than `after`, oldest first. Another user of the same org sees none of
them.

| Query | Default | Meaning |
| --- | --- | --- |
| `after` | `0` | The cursor: return changes with `hubSeq > after`. |
| `limit` | `1000` | Page size, clamped to 1 to 1000. |
| `wait` | `0` | Seconds to wait for a change when there is none yet, capped at 25. |

A non-numeric value for any of the three is `400 invalid_request`. Unknown parameters are ignored.

`200`:

```json
{"changes": [ <StoredChange>, ... ], "next": 12, "more": false}
```

- `next` is the cursor for the next request: the last returned `hubSeq`, or the requested `after`
  when the page is empty. Always pass it back as `after`.
- `more` is `true` when another page follows immediately; ask again with `wait=0`. A page ends
  early, with `more` true, when it holds `limit` changes or when adding the next change would take
  the page's summed `value` sizes (serialised JSON bytes, 0 for no value) past 8 MiB; it always
  holds at least one change, so a page of one 2 MiB change still makes progress.

**Long-poll.** With `wait > 0` and nothing newer than `after`, the hub holds the request until a
push to the same org commits, `wait` seconds pass (never more than 25), or the hub begins to shut
down, and then answers with whatever the feed holds at that moment. That may be an empty page
(`changes: []`, `next` equal to `after`): a push by another user of the org wakes the poll without
adding anything visible to this user, and a timeout is simply an empty page. Clients repeat the
request with the same cursor. The hub registers the waiter before it checks the feed, so a push
that commits between the check and the wait cannot be missed.

**Horizon.** The hub keeps the feed for a retention period (`B4HUB_RETENTION_DAYS`, default 30;
a value that is not a whole number of days of at least 1 is a configuration error and `serve`
exits 2). `serve` prunes every org's feed when it starts and every 24 hours after, and
`b4hub prune --older-than-days N [--org <slug>]` does it once (with `DATABASE_ADMIN_URL`; every
org when `--org` is omitted). Pruning deletes the changes received more than that long ago and
every change before them, and records the org's *horizon*: the highest `hubSeq` it deleted. It
never moves down, and the mirrored tables are not touched. A pull whose `after` is below the
horizon (including `after=0` once anything has been pruned, and any negative `after`) can no
longer be served and gets `410 resync_required`. The client then restores from `GET
/v1/snapshot` and continues pulling from the snapshot's `next`. The check and the page are read in
one database snapshot, so a prune that commits during a pull cannot leave the reader missing rows.
Pruning takes the same per-org lock a push holds, for one org's prune at a time, so it never
deletes a row a push is committing.

### `GET /v1/snapshot`

The authenticated user's state, for a reader that got `410 resync_required` (or has nothing yet
and the feed no longer reaches back to `hubSeq` 1). Read in one `REPEATABLE READ` transaction, so
the rows, the clocks, and `next` are one instant while pushes keep landing. Only this user's rows
appear. `200`:

```json
{
  "changes": [ <StoredChange>, ... ],
  "clocks": [ {"table": "threads", "rowId": "thread-1", "column": "title", "hlc": "019a396c76e8-0000-0198..."} ],
  "next": 12
}
```

- `changes` are synthetic `insert`s, one per row, tables in dependency order (`connections`,
  `projects`, `projectFolders`, `threads`, `turns`, `displayItems`, `runtimeRequests`, `drafts`),
  rows within a table by id. Each has `hubSeq` 0, `deviceSeq` 0, `wall` 0, `column` `null`,
  `deviceId` the row's owner (the device of its latest insert), and `value` the row's Mac columns
  (no `org_id`, `user_id`, `device_id`, or `owner_device_id`; `connections.authReference`,
  `localServerId`, and `target` are `null`, as the hub keeps them). `hlc` is the greatest clock of
  any of the row's clocked columns, or `000000000000-0000-<owner device id>` when none was ever
  set, so any later change of the row wins over it.
- `clocks` lists every per-column clock of those rows (`table`, `rowId`, `column`, `hlc`), so the
  client can keep merging by clock after restoring.
- `next` is the cursor to pull from afterwards: the highest `hubSeq` the org's feed had at that
  instant (or the horizon, if pruning has emptied the feed). `GET /v1/changes?after=<next>` is
  then valid and returns what was pushed since.

The response is one JSON document holding the user's whole mirror; the hub does not page it.
Errors: `401 unauthorized`.

**Shutdown.** When the hub receives SIGTERM, every open long-poll is told at once and returns its
current page (typically empty) instead of waiting out its timeout; a long-poll that arrives after
that does not wait at all. The client simply reconnects, normally to the replacement instance.

## Types

### `Change` (the upload shape)

```json
{
  "deviceSeq": 1,
  "wall": 1761900001000,
  "table": "connections",
  "rowId": "conn-1",
  "op": "insert",
  "column": null,
  "value": {"id": "conn-1", "kind": "codex", "label": "Codex", "enabled": true, "profileRevision": 1, "target": "/usr/local/bin/codex", "routeKey": null, "b4Mode": null, "localServerId": null, "authReference": "secret:abc", "nativeScope": "/Users/brian/project", "capabilities": {"streaming": "supported", "native_resume": "supported", "history_retrieval": "supported", "explicit_interruption": "supported", "reconnect": "supported", "permission_decisions": "supported", "user_questions": "unsupported", "model_selection": "unverified"}, "status": "ready", "authStatus": "authenticated", "createdAt": "2026-10-31T12:00:00Z", "updatedAt": "2026-10-31T12:00:00Z"},
  "hlc": "019a396c76e8-0000-01a194cf-0d12-7418-b3b5-5559dbee2441"
}
```

That is the first of the twelve changes in `Tests/Fixtures/sync/changes.json` (which also carries each change's `hlc`), the fixture the
Swift client and the hub both test against. The fixture is a bare array of `Change`; a push wraps
it as `{"changes": [...]}`. It shows the client's pre-upload shape, not what goes on the wire: the
coordinator blanks `connections.authReference`, `connections.localServerId`, and
`connections.target`, sends a `nativeScope` that contains `/` (a URL or a path) as `scope:` plus
16 hex characters of its SHA-256, and replaces over-large payloads before it sends anything. The file
deliberately holds one `displayItems` change (`deviceSeq` 7) whose `value` is just over the hub's
2 MiB limit, so pushing the raw array answers `200` with that change in `rejected` (`payload_too_large`) and the
other eleven applied; do not paste it whole.

| Field | Type | Meaning |
| --- | --- | --- |
| `deviceSeq` | integer | The change's sequence on the device that wrote it: unique per device, increasing. The idempotency key together with the authenticated device. |
| `wall` | integer | Milliseconds since the epoch on the origin device. |
| `table` | string | One of `connections`, `projects`, `projectFolders`, `threads`, `turns`, `displayItems`, `runtimeRequests`, `drafts`. Any other name (including `localServers`, which never syncs) is recorded and skipped. |
| `rowId` | string | The row's key: its `id`, or `threadId` for `drafts`. Client-chosen text; unique per org within a table. |
| `op` | `"insert"`, `"update"`, or `"delete"` | |
| `column` | string or `null` | For `update`, the column being set; otherwise absent or `null`. |
| `hlc` | string, optional | The hybrid logical clock the device stamped on the change (see *Clocks and the write rule*). Omit it and the hub derives one from `wall`. A value not in the clock form gets that change rejected with `invalid_clock`. |
| `value` | any JSON or `null` | For `insert`, the whole row as an object keyed by the Mac's camelCase column names; for `update`, the column's new value (absent or `null` sets it to NULL); for `delete`, absent. At most 2 MiB serialised. |

Unknown fields are rejected (`400 invalid_request`). Column names are the Mac schema's quoted
camelCase names; ownership columns (`org_id`, `user_id`, `device_id`) can only come from the token.

### `StoredChange` (the feed shape)

A `Change` plus where it sits in the feed and who wrote it:

```json
{
  "hubSeq": 1,
  "deviceId": "0198...",
  "deviceSeq": 1,
  "wall": 1761900001000,
  "table": "connections",
  "rowId": "conn-1",
  "op": "insert",
  "column": null,
  "value": { "...": "as uploaded" },
  "hlc": "019a396c76e8-0000-01a194cf-0d12-7418-b3b5-5559dbee2441"
}
```

`hubSeq` is the org-wide feed position and the pull cursor; `deviceId` is the UUID of the device
that uploaded the change; `hlc` is the change's clock after the hub's clamp, always present. `value` is the uploaded JSON, stored as `jsonb`: equal as JSON, but
object key order is not preserved and duplicate keys collapse.

## Shutdown

On SIGTERM (or SIGINT) the hub fails `/readyz` with `503 shutting_down` first, wakes every open
long-poll so each returns its current page, keeps the listener open for a short readiness grace
(a quarter of the shutdown wait, at most 500 ms) so a load balancer stops routing here, then stops
accepting connections and lets in-flight requests finish. The whole sequence is bounded by
`B4HUB_SHUTDOWN_WAIT_MS` (default 30000) from the moment the signal arrives; anything still open
then is dropped and the process exits.
