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
| 400 | `invalid_request` | request | The body is not valid JSON for the endpoint (malformed JSON, an unknown or missing field, a wrong value type, a missing or wrong `Content-Type`); a `deviceName` or `platform` that fails validation; a push with more than 1000 changes; a non-numeric `after`, `limit`, or `wait`; a link request that is not a WebSocket upgrade or whose `B4-Protocol` is not a whole number. |
| 401 | `unauthorized` | request | The bearer token is missing, malformed, unknown, or belongs to a revoked device. |
| 401 | `invalid_code` | request | The enrollment code is wrong, expired, or already used (the three are indistinguishable). |
| 404 | `not_found` | request | No such route, or a resource that does not exist or is not yours. |
| 405 | `method_not_allowed` | request | The route exists but not for that method. |
| 410 | `resync_required` | request | The pull cursor is older than the retention horizon: the hub has pruned the changes after it. Restore from `GET /v1/snapshot` (see *Horizon*). |
| 413 | `payload_too_large` | request | A push body over 32 MiB. (A change whose `value` is over 2 MiB is rejected per change instead; see `POST /v1/changes`.) |
| 429 | `rate_limited` | request | A device opened too many relay links in a minute (the upgrade is refused before it happens), or a user minted an eleventh pairing code in an hour. Always with `details.retryAfterMs`; on the link it is also a `reply` error for a command over its limits (see *Link*, *Commands*). |
| 500 | `internal_error` | execution | Any unexpected failure; the cause is logged on the hub, never sent. |
| 503 | `not_ready` | execution | `/readyz`: the database is unreachable or migrations are pending. |
| 503 | `shutting_down` | execution | `/readyz` after SIGTERM. |

Six more codes exist only on the relay link, never as an HTTP status. They arrive in an `error`
frame (a problem with the link or a frame) or in a `reply`'s `error` (a problem with one command):

| `code` | `kind` | When |
| --- | --- | --- |
| `device_offline` | execution | The Mac that owns the thread has no open link. `details: { deviceId, deviceName, lastSeenAt }`. |
| `command_expired` | execution | The command's deadline passed before the Mac ran it. |
| `relay_timeout` | execution | The Mac did not reply within the reply wait. |
| `link_replaced` | request | A newer link from the same device closed this one (close code 4000). |
| `client_too_old` | request | The client's `B4-Protocol` is below the hub's minimum. |
| `watch_limit` | request | The link already watches four threads. |

### Limits

| Limit | Value | Applies to |
| --- | --- | --- |
| Change `value` | 2 MiB (2,097,152 bytes of its serialised JSON) | each change in a push; over it, that change is rejected (`rejected: [{deviceSeq, code: "payload_too_large"}]`) and not stored, and the rest of the batch lands |
| Push body | 32 MiB | `POST /v1/changes`; over it, `413 payload_too_large` |
| `MAX_PUSH_CHANGES` | 1000 changes | one push; over it, `400 invalid_request` |
| Pull page | 1000 changes (`limit` is clamped to 1 to 1000; default 1000), and 8 MiB (8,388,608 bytes) of `value` summed over the page (each sized when pushed, as PostgreSQL's `jsonb` text, a few bytes more than compact JSON); whichever comes first, and always at least one change | `GET /v1/changes` |
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

### `POST /v1/pairing-codes`

A joined Mac mints a code that pairs a phone. Bearer auth; no body. Only a `macos` device may
mint: an `ios` or `cli` caller gets `404 not_found`, as if the route did not exist. The code is an
ordinary enrollment code (same alphabet, hashing, and case-insensitive match) that expires in
five minutes instead of ten and is single-use. The phone redeems it at `POST /v1/enroll` with
`platform: "ios"` and becomes a device of the same user. The hub remembers which Mac minted it.

`200`:

```json
{"code": "ABCD2345", "expiresAt": "2026-11-01T12:05:00.000000Z", "hubURL": "https://hub.example.com/"}
```

`hubURL` is `B4HUB_PUBLIC_URL`, and is absent when that is not set. Neither the code nor its hash
is logged.

A user may mint 10 codes in any hour. The eleventh is `429 rate_limited` with
`details.retryAfterMs`, the milliseconds until the tenth most recent mint is an hour old; the
refused request stores nothing. Codes of different users are limited separately.

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
immediately; the next request with it is `401 unauthorized`. If the device has an open link
(see *Link*), the hub closes it with code 4001. Errors: `401 unauthorized`.

### `GET /v1/devices/self/link`

The device's WebSocket link to the relay. See *Link*.

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
is not `{"changes": [...]}` or has more than 1000 changes; `413 payload_too_large` for a body over
32 MiB. (A single change whose `value` is over 2 MiB is not a 413: it is a per-change `rejected`
entry.) Pushes to one org are serialised, so commit order is `hubSeq` order.

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
every insert and update, whatever the change carries. `connections.projectId`, the Mac project a
`b4` connection serves, is not scrubbed and is Mac-only like every column not listed above; it
merges by hub order (`hubSeq`), not by clock.

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

- `next` is the cursor for the next request; always pass it back as `after`. When `more` is true
  it is the last returned `hubSeq`. Otherwise the page reached the end of your feed and `next` is
  the highest `hubSeq` the org has recorded (at least the requested `after`), even when that is
  another user's change: none of yours lies in between, because pushes commit in `hubSeq` order.
  So a user with nothing new still moves forward and is not left behind the retention horizon by
  other users' activity.
- `more` is `true` when another page follows immediately; ask again with `wait=0`. A page ends
  early, with `more` true, when it holds `limit` changes or when adding the next change would take
  the page's summed `value` sizes (as stored with each change, 0 for no value) past 8 MiB; it always
  holds at least one change, so a page of one 2 MiB change still makes progress.

**Long-poll.** With `wait > 0` and nothing newer than `after`, the hub holds the request until a
push to the same org commits, `wait` seconds pass (never more than 25), or the hub begins to shut
down, and then answers with whatever the feed holds at that moment. That may be an empty page
(`changes: []`, `next` at least `after`): a push by another user of the org wakes the poll without
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
  "value": {"id": "conn-1", "kind": "codex", "label": "Codex", "enabled": true, "profileRevision": 1, "target": "/usr/local/bin/codex", "routeKey": null, "b4Mode": null, "localServerId": null, "authReference": "secret:abc", "nativeScope": "/Users/brian/project", "projectId": "project-1", "capabilities": {"streaming": "supported", "native_resume": "supported", "history_retrieval": "supported", "explicit_interruption": "supported", "reconnect": "supported", "permission_decisions": "supported", "user_questions": "unsupported", "model_selection": "unverified"}, "status": "ready", "authStatus": "authenticated", "createdAt": "2026-10-31T12:00:00Z", "updatedAt": "2026-10-31T12:00:00Z"},
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

## Link

`GET /v1/devices/self/link` upgrades to a WebSocket that carries the relay: a phone's commands to
the Mac, the Mac's replies and live events back, and which Macs are online. The frames are JSON
text, one message each, with a `type` discriminator; absent optional fields are omitted, never
`null`. `Tests/Fixtures/sync/relay.json` holds one example of every frame, and both the hub's and
the Swift clients' test suites decode it. This section describes the link itself, presence,
commands, and live progress (watching and events).

### Opening a link

```
GET /v1/devices/self/link
Authorization: Bearer <device token>
B4-Protocol: 1
Upgrade: websocket
```

Authentication happens before the upgrade, so a bad token is the usual `401 unauthorized` and no
socket. A request that is not a WebSocket upgrade is `400 invalid_request`. A device may attempt
10 upgrades a minute (a sliding window per device, counted after authentication); the 11th is
`429 rate_limited` with `retryAfterMs` and no socket. During shutdown the answer is
`503 shutting_down`.

`B4-Protocol` is the device's link protocol; a missing header counts as `1`, and a value that is
not a whole number is `400 invalid_request`. The role comes from the device, not the request: a
`macos` device is a **host**, an `ios` or `cli` device is a **client**.

One link per device. A newer link from a device replaces its older one: the older gets an `error`
frame `link_replaced`, then close code 4000. The replaced device does not go offline.

### Frames in this version

| Direction | `type` | Body |
| --- | --- | --- |
| hub to device | `hello` | `protocol` (1), `minClientProtocol`, `deviceId`, `role` (`host` or `client`), `heartbeatSeconds` (10), `hubTime` |
| device to hub | `ping` | none |
| hub to device | `pong` | `hubTime` |
| hub to client | `presence` | `hosts: [{ deviceId, name, online, lastSeenAt? }]` |
| client to hub | `watch` | `threadId` |
| client to hub | `unwatch` | `threadId` |
| hub to host | `watching` | `threadIds`: every thread of this Mac that some client watches |
| host to hub | `event` | `event`: an object with a string `threadId` |
| hub to client | `event` | the same |
| hub to client | `stream_gap` | `threadId` |
| client to hub | `command` | `id`, `method`, `params` |
| hub to host | `command` | `id`, `method`, `params`, `deadline`, `from: { deviceId, name }` |
| host to hub | `reply` | `id`, and `result` or `error: { code, message, details? }` |
| hub to client | `reply` | the same |
| hub to device | `error` | `code`, `message`, `details?` |

`hello` is the hub's first frame on every link. `hubTime` is the hub's clock, RFC 3339 in UTC with
milliseconds (`2026-11-01T09:30:00.123Z`); a host uses the `hubTime` of `hello` and `pong` to
estimate the hub's clock. A device whose `B4-Protocol` is below the hub's `minClientProtocol` gets
no `hello`: it gets an `error` frame `client_too_old` (`details: { minClientProtocol }`) and then
close code 4002.

A frame that is not valid JSON, not a relay message, binary, or not one the device may send gets
an `error` frame `invalid_request`; the link stays up. A device may send `ping`; a client may also
send `command`, `watch`, and `unwatch`, and a host `reply` and `event`. (A `command` with an
unknown method is answered as a command; see *Commands*. A frame over the size limit is refused
the same way; see *Frame size*.)

### Heartbeat

The device sends `ping` every 10 seconds and the hub answers `pong`. Any frame from the device
(including a WebSocket protocol ping) counts as the link being alive. The hub closes a link that
has sent nothing for 30 seconds with code 4003; a device that has received nothing for 30 seconds
treats the link as dead and reconnects.

### Presence

A host is online while it has a link. A client receives `presence` once after `hello`, then again
whenever one of its user's Macs goes online or offline: `hosts` is every non-revoked `macos`
device of that user (never another user's), with `online` and `lastSeenAt` (RFC 3339 in UTC with
milliseconds; omitted for a Mac never seen). A Mac that is revoked drops out of the list.

Presence is never lost to a busy phone. If a client's outbound queue is full when presence
changes, the hub keeps the latest presence for that link, replacing the one it was keeping, and
queues it as soon as the queue has room. A phone that reads again therefore gets the current
presence once, after the frames that were already queued, and never an older one after a newer.

`devices.last_seen_at` is written when a link opens, at most once a minute while it is open, and
when it closes, where it is the time of the link's **last received frame**, not the moment the
hub noticed the drop: a link closed for 30 seconds of silence reports a time 30 seconds in the
past. It never moves backwards.

### Commands

A client sends `command { id, method, params }`; `id` is the client's own lowercase UUID, and for
`turn.send` and `thread.start` it is also the turn's `operationId`, so a resend with the same `id`
is safe. The hub forwards it to the Mac that owns what it names and sends the Mac's `reply` back,
or answers itself with a `reply` whose `error` is one of the codes below. Every command gets
exactly one `reply` with its `id`; nothing is stored, and the hub never reads `params` beyond the
ids it routes by, nor `result` at all.

| `method` | Routed by | to the owner of |
| --- | --- | --- |
| `turn.send` | `params.threadId` | the thread |
| `turn.interrupt` | `params.threadId` | the thread |
| `turn.lookup` | `params.threadId` | the thread |
| `request.respond` | `params.requestId` | the runtime request's thread (`"runtimeRequests"."threadId"`) |
| `thread.start` | `params.projectId` | the project |

The owner is the row's `owner_device_id` on the hub (the device whose push inserted it). The hub
checks, in this order:

1. **Role and method.** A `command` from a host link, or with a method outside the five, is
   `not_found` (a host never sends commands; an unknown method answers by the frame's `id`).
2. **Limits.** (A resend of a command still in flight is not counted; see *In flight*.) A client device may send 60 commands a minute (a sliding window), in bursts of at
   most 20 (after a burst, one a second). A user's `turn.send` and `thread.start` together are
   limited to 20 a minute across all of their devices. Over a limit the answer is `rate_limited`
   with `details.retryAfterMs`. A command refused by the user's limit still counts toward the
   device's. Limits are in memory and per hub process.
3. **Lookup.** The row is looked up by id within the caller's org and user. A missing row,
   another user's or another org's, a missing routing param, and a row whose owner is not a
   non-revoked `macos` device of the caller's own user all answer `not_found`, the same way.
4. **Already answered.** `request.respond` for a request whose state on the hub is set and is not
   `pending` is `stale_runtime_request` at once, without forwarding. (The Mac stays the authority:
   a request the hub has not yet seen answered is forwarded, and the Mac answers the same code.)
5. **Delivery.**
   - **Owner online:** the command is forwarded with `deadline` (the hub's time plus 10 seconds,
     RFC 3339 in UTC with milliseconds; the Mac drops a command past it and answers
     `command_expired`) and `from` (the calling device's id and name). If the Mac's link dropped
     meanwhile the answer is `device_offline`; if its outbound queue stays full for 5 seconds the
     answer is `relay_timeout` (the Mac is online but not taking frames in time).
   - **Owner offline, `turn.send`, `thread.start`, or `turn.lookup`:** `device_offline` at once,
     with `details: { deviceId, deviceName, lastSeenAt }` (`lastSeenAt` omitted for a Mac never
     seen). These are never held.
   - **Owner offline, `turn.interrupt` or `request.respond`:** if the Mac was last heard from less
     than 60 seconds ago, the command is held in memory until the Mac links again, and then
     forwarded (after its `hello`) with a fresh deadline; if `lastSeenAt + 60 s` passes first, the
     answer is `device_offline`. A Mac last seen longer ago gets `device_offline` at once. At most
     32 commands are held for one Mac; beyond that, `device_offline` at once.
6. **Reply wait.** The hub waits 30 seconds for the Mac's `reply` to `turn.send` and
   `thread.start`, 15 seconds for the others (counted from when it was forwarded), then answers
   `relay_timeout`. A `reply` that arrives later, or for an `id` nothing waits for, is dropped.

**In flight.** A command is in flight from when it arrives (before the limits) until its answer is
queued for the caller, keyed by the calling *device* and the `id`. A second command with the same
key while the first is in flight attaches to it: it is not counted against the limits, not
forwarded again, and the device gets one `reply`. The answer goes to the calling device's link as
it is when the answer is ready, so a phone that links again mid-command gets the reply on its new
link. If the caller's outbound queue is full, the reply waits up to 5 seconds for room (it is
never dropped for a momentarily full queue, unlike `event` frames); a device with no link, or
whose queue stays full that long, misses it (the phone settles a send with `turn.lookup`). The map lives in memory: after a hub restart, a resend of the same `id` is
forwarded to the Mac again, and the Mac recognises it.

**A thread just started.** When the hub forwards `thread.start`, it remembers for 5 minutes that
`params.threadId` belongs to that Mac, for that user, and consults this before the thread lookup.
So `turn.send` (and `turn.interrupt`, `turn.lookup`) reach the new thread before the Mac's next
push brings its row. Another user's command for that thread id is still `not_found`.

A host answers each forwarded command once with `reply { id, result }` or
`reply { id, error }`; the hub passes the Mac's own error codes (`stale_runtime_request`,
`command_expired`, `protocol_invalid`, ...) through unchanged. A `reply` from a client is
`invalid_request`. The hub logs each command's method, outcome, and latency, and limit hits; never
its params, its result, or a token.

| Hub-made answer | When |
| --- | --- |
| `not_found` | role, method, lookup, or owner check failed (steps 1 and 3) |
| `rate_limited` | a limit (step 2); `details.retryAfterMs` |
| `stale_runtime_request` | step 4 |
| `device_offline` | step 5; `details: { deviceId, deviceName, lastSeenAt? }` |
| `relay_timeout` | step 6, or step 5 when the Mac's queue stays full for 5 seconds |
| `internal_error` | the hub could not read the database to route the command |

### Watching and live events

A phone that has a thread open sends `watch { threadId }`, and `unwatch { threadId }` when it
leaves the thread or goes to the background. The hub tells the thread's Mac which threads to
stream, and passes the Mac's `event` frames on to the phones that watch their thread. Nothing here
is stored: a lost event is harmless, because the change log is the record.

**`watch`.** Authorised like `turn.send`: the thread must be one the caller's user may reach, found
in the pending-thread map (see *A thread just started*) first and then the thread table, and its
owner must be a non-revoked `macos` device of the caller's own user. Otherwise the hub answers an
`error` frame `not_found`; a missing thread, another user's, another org's, and one owned by
a device that is not the user's Mac all read the same. A success has no answer. The Mac need not
be online: the watch is kept and the Mac is told when it links. The same link may watch a thread it
already watches (nothing changes). At most **4** threads per link: a fifth distinct thread gets an
`error` frame `watch_limit`, and the link and its other watches are untouched. `unwatch` of a
thread that is not watched is ignored. Watches belong to the link: they end when it closes, and a
device's newer link (which replaces the older) starts with none. A phone therefore sends `watch`
again after every reconnect. A host sending `watch` or `unwatch`, or a client sending `watching`,
`event`, or `stream_gap`, gets `invalid_request`.

**Auto-watch.** When the hub forwards `thread.start`, the caller's link starts watching the new
thread, so the first turn streams without a race against a `watch`. It counts toward the link's 4
(if the link is already at 4 the thread is simply not auto-watched, and the phone can `unwatch`
another and `watch` it). A `thread.start` the Mac then refuses leaves the watch in place until the
phone unwatches it or the link closes.

**`watching`.** The hub keeps, per host, the set of that host's threads that any client link
watches, and sends the **whole** set to the host as `watching { threadIds }` (sorted) right after
`hello` (an empty set when nothing is watched, so a Mac that linked again forgets what it knew),
and again every time the set changes, including when a watching phone's link closes. A change that
leaves the host's set the same (a second phone watching a thread already in it) sends nothing.
The frame is written by the host's link itself, so it is never dropped for a full queue and
two changes are never reordered. A host streams events only for threads in its latest set.

**`event`.** A host sends `event { event }`, where `event` is an object with a string `threadId`;
the hub reads that one field. If no client link watches that thread of that host, or `threadId` is
missing or not a string, the event is dropped without an answer. Otherwise it is queued, unchanged,
to each watching client link. The hub does not look at the event's kind or content and never logs
them; which kinds are streamed, and the 256 KiB bound, are the Mac's to apply.

**Backpressure and `stream_gap`.** Each link has an outbound queue of 256 frames. When a client's
queue is full, an `event` for it is dropped (never blocking the Mac or other phones) and the
thread is marked as having a gap for that link. As soon as the queue has room, the hub queues one
`stream_gap { threadId }` per marked thread, behind everything already queued; events for the
marked thread are dropped until that is done, so the `stream_gap` always comes after the hole it
reports and before anything newer. A phone that gets `stream_gap` drops that thread's in-flight
text and waits for sync. Frames other than `event` (replies, errors, presence) are not dropped:
replies and errors wait for room, and presence is kept as described under *Presence*.

### Close codes

| Code | Meaning | The device should |
| --- | --- | --- |
| 1001 | the hub is shutting down | reconnect with backoff |
| 4000 | replaced by a newer link of the same device (after an `error` frame `link_replaced`) | not reconnect |
| 4001 | the device was revoked | stop until it joins again |
| 4002 | `client_too_old` | stop and update |
| 4003 | no frame for 30 seconds | reconnect with backoff |

Reconnect backoff is 1 second doubling to 30 (15 on the phone) with full jitter, reset after a
link has stayed up for 60 seconds.

### Frame size

A frame is one WebSocket text message. The hub refuses a frame from a **client** over **64 KiB**
(65,536 bytes) and from a **host** over **256 KiB** (262,144 bytes) with an `error` frame
`invalid_request` (`details: { maxBytes }`); the frame is not read, not echoed, and not logged,
and the link stays up. A frame of exactly the limit is accepted. The limits are on what a device
sends: a phone can receive a 256 KiB `event`. Beneath that, the WebSocket layer reads no message
over 1 MiB: such a message ends the connection (with no close code), so a device must not send one.

| Limit | Value |
| --- | --- |
| Frame from a client | 64 KiB |
| Frame from a host | 256 KiB |
| Watched threads per client link | 4 |
| Outbound queue per link | 256 frames |

## Shutdown

On SIGTERM (or SIGINT) the hub fails `/readyz` with `503 shutting_down` first, wakes every open
long-poll so each returns its current page, keeps the listener open for a short readiness grace
(a quarter of the shutdown wait, at most 500 ms) so a load balancer stops routing here, then stops
accepting connections and lets in-flight requests finish. Every open link is closed with code
1001 as soon as shutdown begins (an upgraded connection is no longer an in-flight request, so the
drain waits for the links separately). The whole sequence is bounded by
`B4HUB_SHUTDOWN_WAIT_MS` (default 30000) from the moment the signal arrives; anything still open
then is dropped and the process exits.
