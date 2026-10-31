# Hub HTTP API

The hub speaks JSON over HTTP. This document describes what the code in `crates/b4hub` does;
where the two disagree, the code is right and this file is the bug.

All paths are relative to the hub's base URL (`http://localhost:8080` for the Compose stack).
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
| 410 | `resync_required` | request | The pull cursor is older than the retention horizon (see below). |
| 413 | `payload_too_large` | request | A push body over 32 MiB, or any change whose `value` is over 2 MiB. |
| 500 | `internal_error` | execution | Any unexpected failure; the cause is logged on the hub, never sent. |
| 503 | `not_ready` | execution | `/readyz`: the database is unreachable or migrations are pending. |
| 503 | `shutting_down` | execution | `/readyz` after SIGTERM. |

### Limits

| Limit | Value | Applies to |
| --- | --- | --- |
| Change `value` | 2 MiB (2,097,152 bytes of its serialised JSON) | each change in a push; over it, the whole batch is refused with `413 payload_too_large` before anything is stored |
| Push body | 32 MiB | `POST /v1/changes`; over it, `413 payload_too_large` |
| `MAX_PUSH_CHANGES` | 1000 changes | one push; over it, `400 invalid_request` |
| Pull page | 1000 changes (`limit` is clamped to 1 to 1000; default 1000) | `GET /v1/changes` |
| Long-poll `wait` | 25 seconds | `GET /v1/changes`; a larger `wait` is clamped to 25 |
| Other request bodies | 2 MiB (axum's default) | `POST /v1/enroll` |

The Mac client sends batches of 500 and replaces a `displayItems.payload` over 1 MiB with
`{"truncated": true, "bytes": n}` before upload, so the hub's 2 MiB limit only ever refuses a
broken or hostile client. The hub refuses; it never truncates.

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

`acceptedThrough` is the highest `deviceSeq` in the batch (for an empty batch, the highest
`deviceSeq` this device has had accepted so far, or `0`). A client marks local rows `synced` only
once `acceptedThrough` covers them.

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
32 MiB or a change whose `value` is over 2 MiB. Pushes to one org are serialised, so commit order
is `hubSeq` order.

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
- `more` is `true` when another page follows immediately; ask again with `wait=0`.

**Long-poll.** With `wait > 0` and nothing newer than `after`, the hub holds the request until a
push to the same org commits, `wait` seconds pass (never more than 25), or the hub begins to shut
down, and then answers with whatever the feed holds at that moment. That may be an empty page
(`changes: []`, `next` equal to `after`): a push by another user of the org wakes the poll without
adding anything visible to this user, and a timeout is simply an empty page. Clients repeat the
request with the same cursor. The hub registers the waiter before it checks the feed, so a push
that commits between the check and the wait cannot be missed.

**Horizon.** The hub keeps the feed back to a retention horizon; a cursor behind it can no longer
be served and gets `410 resync_required`, after which the client starts again from the beginning
(`after=0`). M8a never prunes, so the horizon is `0` and the only cursors that fail are negative
ones.

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
  "value": {"id": "conn-1", "kind": "codex", "label": "Codex", "enabled": true, "profileRevision": 1, "target": "/usr/local/bin/codex", "routeKey": null, "b4Mode": null, "localServerId": null, "authReference": "secret:abc", "nativeScope": "/Users/brian/project", "capabilities": {"streaming": true, "approvals": true, "resume": true}, "status": "ready", "authStatus": "authenticated", "createdAt": "2026-10-31T12:00:00Z", "updatedAt": "2026-10-31T12:00:00Z"}
}
```

That is the first of the twelve changes in `Tests/Fixtures/sync/changes.json`, the fixture the
Swift client and the hub both test against. The fixture is a bare array of `Change`; a push wraps
it as `{"changes": [...]}`. It shows the client's pre-upload shape, not what goes on the wire: the
coordinator blanks `connections.authReference`, `connections.localServerId`, and
`connections.target` and replaces over-large payloads before it sends anything. The file
deliberately holds one `displayItems` change (`deviceSeq` 7) whose `value` is just over the hub's
2 MiB limit, so pushing the raw array is refused whole with `413 payload_too_large`; do not paste
it whole.

| Field | Type | Meaning |
| --- | --- | --- |
| `deviceSeq` | integer | The change's sequence on the device that wrote it: unique per device, increasing. The idempotency key together with the authenticated device. |
| `wall` | integer | Milliseconds since the epoch on the origin device. |
| `table` | string | One of `connections`, `threads`, `turns`, `displayItems`, `runtimeRequests`, `drafts`. Any other name (including `localServers`, which never syncs) is recorded and skipped. |
| `rowId` | string | The row's key: its `id`, or `threadId` for `drafts`. Client-chosen text; unique per org within a table. |
| `op` | `"insert"`, `"update"`, or `"delete"` | |
| `column` | string or `null` | For `update`, the column being set; otherwise absent or `null`. |
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
  "value": { "...": "as uploaded" }
}
```

`hubSeq` is the org-wide feed position and the pull cursor; `deviceId` is the UUID of the device
that uploaded the change. `value` is the uploaded JSON, stored as `jsonb`: equal as JSON, but
object key order is not preserved and duplicate keys collapse.

## Shutdown

On SIGTERM (or SIGINT) the hub fails `/readyz` with `503 shutting_down` first, wakes every open
long-poll so each returns its current page, keeps the listener open for a short readiness grace
(a quarter of the shutdown wait, at most 500 ms) so a load balancer stops routing here, then stops
accepting connections and lets in-flight requests finish. The whole sequence is bounded by
`B4HUB_SHUTDOWN_WAIT_MS` (default 30000) from the moment the signal arrives; anything still open
then is dropped and the process exits.
