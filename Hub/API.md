# Hub HTTP API

The hub speaks JSON over HTTP. This document describes what the code in `crates/b4hub` does;
where the two disagree, the code is right and this file is the bug.

All paths are relative to the hub's base URL (`http://localhost:8080` for the Compose stack, which publishes the port on `127.0.0.1` only).
Clients refuse any non-HTTPS URL whose host is not `localhost`, `127.0.0.1`, or `::1`.

## Conventions

### Authentication

Every route except `/healthz`, `/readyz`, `POST /v1/enroll` (where the header is optional and
asks for a merge; see that route), and the sign-in routes under `/v1/auth/` requires

```
Authorization: Bearer <device token>
```

The scheme is matched case-insensitively; the token must be non-empty and contain no whitespace.
The token comes from `POST /v1/enroll` or a sign-in (`POST /v1/auth/passkey/finish`), the only
places it is ever shown; the hub stores only its SHA-256. Authentication happens before the request body is read, so an unauthenticated
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
answer the same generic `404 not_found`. `rate_limited` alone adds a field,
`details.retryAfterMs` (milliseconds until the client may try again), and a `Retry-After` header
in whole seconds.

| HTTP | `details.code` | `kind` | When |
| --- | --- | --- | --- |
| 400 | `ceremony_expired` | request | A sign-in ceremony that is unknown, expired (5 minutes), already finished, or (for a sign-up) was begun while sign-up was closed; the cases are indistinguishable. Begin again. |
| 400 | `invalid_request` | request | The body is not valid JSON for the endpoint (malformed JSON, an unknown or missing field, a wrong value type, a missing or wrong `Content-Type`); a `deviceName`, `platform`, or `fullName` that fails validation; a push with more than 1000 changes; a non-numeric `after`, `limit`, or `wait`. |
| 401 | `unauthorized` | request | The bearer token is missing, malformed, unknown, or belongs to a revoked device. |
| 401 | `invalid_code` | request | The enrollment code is wrong, expired, or already used (the three are indistinguishable). |
| 401 | `credential_rejected` | request | A sign-in credential failed verification: a malformed WebAuthn response, a wrong origin or relying party, a bad signature, a passkey no account has, a user handle that is not the passkey's, a counter that went backwards, or a new passkey that already belongs to an account. Deliberately vague. |
| 403 | `signup_closed` | request | A sign-up (a passkey `attestation`) while the hub's sign-up policy is `closed`. |
| 404 | `not_found` | request | No such route, or a resource that does not exist or is not yours (including another account's identity id). |
| 405 | `method_not_allowed` | request | The route exists but not for that method. |
| 409 | `last_identity` | request | `DELETE /v1/me/identities/{id}` of the account's only sign-in method, which would leave it unable to sign in. Add another first. |
| 409 | `merge_refused` | request | `POST /v1/enroll` with a token whose account cannot be merged into the code's: it has (or ever had) a `macos` device, it is a member of a shared org rather than the owner of a personal one, or it is the code's own account. Nothing changes, and the code stays redeemable. |
| 409 | `shared_org` | request | `DELETE /v1/me` by a member of a shared (non-personal) org, such as an operator-seeded user; only the owner of a personal org can delete their account here. Nothing is revoked or deleted. |
| 410 | `resync_required` | request | The pull cursor is older than the retention horizon: the hub has pruned the changes after it. Restore from `GET /v1/snapshot` (see *Horizon*). |
| 413 | `payload_too_large` | request | A push body over 32 MiB. (A change whose `value` is over 2 MiB is rejected per change instead; see `POST /v1/changes`.) |
| 429 | `rate_limited` | request | Too many sign-in requests from this client this minute (see *Limits*); `details.retryAfterMs` says how long to wait. |
| 500 | `internal_error` | execution | Any unexpected failure; the cause is logged on the hub, never sent. |
| 503 | `not_ready` | execution | `/readyz`: the database is unreachable or migrations are pending. |
| 503 | `shutting_down` | execution | `/readyz` after SIGTERM. |

### Limits

| Limit | Value | Applies to |
| --- | --- | --- |
| Change `value` | 2 MiB (2,097,152 bytes of its serialised JSON) | each change in a push; over it, that change is rejected (`rejected: [{deviceSeq, code: "payload_too_large"}]`) and not stored, and the rest of the batch lands |
| Push body | 32 MiB | `POST /v1/changes`; over it, `413 payload_too_large` |
| `MAX_PUSH_CHANGES` | 1000 changes | one push; over it, `400 invalid_request` |
| Pull page | 1000 changes (`limit` is clamped to 1 to 1000; default 1000), and 8 MiB (8,388,608 bytes) of `value` summed over the page (each sized when pushed, as PostgreSQL's `jsonb` text, a few bytes more than compact JSON); whichever comes first, and always at least one change | `GET /v1/changes` |
| Retention | `B4HUB_RETENTION_DAYS`, default 30 | how long the hub keeps the change log (see *Horizon*) |
| Long-poll `wait` | 25 seconds | `GET /v1/changes`; a larger `wait` is clamped to 25 |
| Other request bodies | 2 MiB (axum's default) | `POST /v1/enroll`, `POST /v1/auth/passkey/finish`, `PUT /v1/me/profile`, `POST /v1/me/passkeys/finish` |
| Sign-in begins | 20 per client IP per minute | `POST /v1/auth/passkey/begin` and `POST /v1/me/passkeys/begin`, together; over it, `429 rate_limited` |
| Sign-in finishes | 10 per client IP per minute | `POST /v1/auth/passkey/finish` and `POST /v1/me/passkeys/finish`, together, counted before the token is checked or the body read; over it, `429 rate_limited` |
| Full name | 1 to 200 characters after trimming | `PUT /v1/me/profile` |
| Ceremony lifetime | 5 minutes, single use | a `ceremonyId` from a begin |

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

Exchange a one-time enrollment code for a device token. The code is the credential; the
`Authorization` header is optional (see *Merging a phone-only account* below). The operator mints a code with `b4hub enroll --user <username>`; it is eight
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

**Merging a phone-only account.** A phone already signed in to an account of its own (one it
signed up with, which has never had a Mac) sends that account's token,
`Authorization: Bearer <phone token>`, so pairing does not leave the person with two accounts. In
one transaction the hub claims the code, moves every identity (passkeys, Apple IDs) of the
token's account to the code's user, deletes that account's devices (so the phone's old token
stops working at once), tokens, user, and personal org (which holds no synced rows: only a Mac
writes them), and enrolls the new device under the code's account. The answer is the same `200`
as above, for the code's account. If any step fails nothing has changed: a wrong, expired, or used
code is `401 invalid_code` and the phone's account and token are untouched.

- A header that is present but not a valid token (another scheme, malformed, unknown, revoked) is
  `401 unauthorized`, before the code is looked at.
- A token whose account has (or had) a `macos` device, belongs to a shared org, or is the code's
  own account is `409 merge_refused`, and the code stays redeemable.
- Without the header, enrollment is exactly as before.

### Sign-in

Signing in (or up) ends in a device token, exactly as enrollment does. These routes take no
`Authorization` header.

**Configuration.** `serve` requires `B4HUB_WEBAUTHN_RP_ID`, the passkey relying party (the site
domain, for example `b4.run`; Compose defaults it to `local.b4.run`), and `B4HUB_SECRET_KEY` (32
random bytes in base64); without either it exits 2. The WebAuthn origin is `https://<rp id>`.
`B4HUB_SIGNUP` is `open` or `closed` (default `closed`, so an on-prem hub never grows accounts by
accident; Compose's `.env.example` sets `open`). `B4HUB_TRUST_X_FORWARDED_FOR=1` makes the rate
limits count the right-most `X-Forwarded-For` entry instead of the TCP peer (a bare address,
`a.b.c.d:port`, `[v6]`, or `[v6]:port`; anything else falls back to the peer). Set it only behind
exactly one proxy that appends that header: behind two, the right-most entry is the outer proxy
and every client shares its limit. The `B4HUB_APPLE_*` variables are all set or none (any other
combination exits 2); Sign in with Apple's routes are not built yet. Every secret is a plain
environment variable, never a file path. `seed` and `enroll` read none of these.

**Rate limits** are kept in memory per process (a fixed one-minute window per client), so a hub
with several replicas admits a client once per replica. A client is an IPv4 address, or an IPv6
address's /64 prefix (an IPv4-mapped IPv6 peer counts as its IPv4 address). Each limit tracks at
most 100,000 clients and sweeps ended windows once a minute; while it is full, a client it is not
already tracking gets `429 rate_limited` until the next sweep.

**Logging.** No request body of these routes, challenge, credential id, or token is logged. A
failed verification logs `passkey verification failed` with a fixed reason. webauthn-rs logs
whole responses and challenges at DEBUG and TRACE, so the hub's subscriber has a second filter,
separate from `B4HUB_LOG`, that drops every event and span whose target starts with `webauthn`
(`webauthn_rs`, `webauthn_rs_core`, `webauthn_attestation_ca`, and their modules). No
`B4HUB_LOG` directive, module-qualified or not, gets past it.

#### `GET /v1/auth/config`

What this hub offers, so a client hides the rest. Not rate limited. `200`:

```json
{"passkeys": {"rpId": "b4.run"}, "apple": {"native": false, "web": false}, "signup": "open"}
```

`apple` is `false` for both until the Apple routes exist.

#### `POST /v1/auth/passkey/begin`

Begins a passkey ceremony that can end in either a sign-in or a sign-up. No body. `200`:

```json
{
  "ceremonyId": "4f0c...",
  "authentication": {"publicKey": {"challenge": "...", "timeout": 300000, "rpId": "b4.run",
                                   "allowCredentials": [], "userVerification": "required",
                                   "extensions": {"uvm": true}}},
  "registration": {"publicKey": {"rp": {"id": "b4.run", "name": "Agent Workspace"},
                                 "user": {"id": "...", "name": "Agent Workspace account",
                                          "displayName": "Agent Workspace account"},
                                 "challenge": "...", "pubKeyCredParams": [...], "timeout": 300000,
                                 "authenticatorSelection": {"residentKey": "required",
                                                            "requireResidentKey": true,
                                                            "userVerification": "required"},
                                 "attestation": "none", "extensions": {...}}}
}
```

- `ceremonyId` is a random (version 4) UUID, valid for 5 minutes and finished once.
- `authentication` is a WebAuthn `PublicKeyCredentialRequestOptions` wrapper with no
  allow-list, so the OS offers any passkey for the relying party (discoverable credentials).
  Binary fields are base64url without padding.
- `registration` is a `PublicKeyCredentialCreationOptions` wrapper for a new user with a fresh
  random user handle (`user.id`). It is **absent** while sign-up is closed.

Errors: `429 rate_limited`.

#### `POST /v1/auth/passkey/finish`

Finishes the ceremony with the authenticator's response: an `assertion` signs in to the
passkey's account, an `attestation` signs up. Request (exactly one of `assertion` and
`attestation`; no other fields, here or in `device`):

```json
{
  "ceremonyId": "4f0c...",
  "assertion": { <PublicKeyCredential: id, rawId, response {authenticatorData, clientDataJSON,
                  signature, userHandle}, type> },
  "device": {"deviceName": "Brian's MacBook Pro", "platform": "macos", "deviceId": "0198..."}
}
```

- `device.deviceName` and `device.platform` are validated as for `POST /v1/enroll`.
- `device.deviceId` (optional): on a sign-in, when it names an unrevoked device of the same user
  on the same platform, that device is reused, renamed, and its earlier tokens are deleted;
  otherwise a new device is made. A sign-up always makes a new device.
- An **assertion** is verified against the stored ceremony and the passkey found by its
  credential id; its `userHandle` must be the one the passkey was registered with. Each sign-in
  records `last_used_at` and stores the passkey's new signature counter and backup state; a
  counter that does not move forward (when either side is non-zero) is refused, so a cloned key
  is caught. Synced passkeys that always report 0 keep working.
- An **attestation** creates the user (username `u-` and 8 characters), a personal org named
  "My Org", the passkey identity, the device, and its token, in one transaction.

`200`, the same shape for both:

```json
{
  "deviceId": "0198...",
  "token": "<43 characters, base64url>",
  "org": {"slug": "o-k2m4q7xz", "name": "My Org"},
  "user": {"username": "u-a3b9c2d7", "displayName": ""},
  "needsOnboarding": true
}
```

`needsOnboarding` is true until the user has given a full name. The token appears here and
nowhere else.

Validation happens before the ceremony is taken, so a malformed request does not use it up. Of
two finishes of one ceremony racing, exactly one succeeds; the other is `ceremony_expired`.
Errors: `400 invalid_request` (the body's shape, both or neither response, a bad device),
`403 signup_closed` (an attestation while sign-up is closed, checked before the ceremony is
taken), `400 ceremony_expired`, `401 credential_rejected`, `429 rate_limited`.

### `GET /v1/me`

The authenticated device, the org and user it belongs to, and the account's sign-in methods.
`200`:

```json
{
  "deviceId": "0198...",
  "deviceName": "Brian's MacBook Pro",
  "platform": "macos",
  "org": {"slug": "cacheplane", "name": "cacheplane"},
  "user": {"username": "blove", "displayName": "Brian Love", "fullName": "Brian Love"},
  "createdAt": "2026-10-31T12:00:00.000000Z",
  "onboarded": true,
  "identities": [
    {"id": "0199...", "kind": "passkey", "name": "Agent Workspace account",
     "createdAt": "2026-11-01T09:00:00.000000Z", "lastUsedAt": "2026-11-01T10:00:00.000000Z"},
    {"id": "019a...", "kind": "apple", "name": "x7k2@privaterelay.appleid.com",
     "createdAt": "2026-11-01T11:00:00.000000Z", "lastUsedAt": null}
  ]
}
```

- The fields before `onboarded` are unchanged from enrollment, so an older client still decodes
  the answer; `user.fullName`, `onboarded`, and `identities` were added with sign-in.
- `user.fullName` is the name given at onboarding, `null` until then. `onboarded` is false until
  `PUT /v1/me/profile` has been called once (an operator-seeded user counts as onboarded).
- `identities` is every sign-in method of the user, oldest first: `kind` is `passkey` or `apple`;
  `name` is a passkey's name or an Apple ID's (often relay) email, or `null`; `lastUsedAt` is
  `null` for one never used to sign in. An operator-enrolled user may have none. No credential
  id, stored passkey, Apple `sub`, or refresh token is ever included.

Timestamps are RFC 3339 in UTC with microseconds. Errors: `401 unauthorized`.

### `PUT /v1/me/profile`

Onboarding: records the user's full name. Request (no other fields):

```json
{"fullName": "Brian Love"}
```

`fullName` is trimmed and must then be 1 to 200 characters (`400 invalid_request` otherwise,
with nothing changed). The hub stores it as the user's full and display name, marks the user
onboarded (the first time), and renames the user's **personal** org to "<first word>'s Org"
("Brian's Org"); a shared org, such as an operator-seeded one, keeps its name. It may be called
again to change the name, which renames a personal org again. `200` with the `GET /v1/me` answer.
Errors: `400 invalid_request`, `401 unauthorized`.

### `POST /v1/me/passkeys/begin`

Begins adding a passkey to the signed-in user (Settings → Account → Add a passkey; also how an
operator-enrolled user gets their first one). No body. `200`:

```json
{
  "ceremonyId": "4f0c...",
  "registration": {"publicKey": {"rp": {...}, "user": {"id": "...",
                                 "name": "Agent Workspace account",
                                 "displayName": "Agent Workspace account"},
                                 "challenge": "...", "excludeCredentials": [{"type": "public-key",
                                 "id": "..."}], "authenticatorSelection": {"residentKey":
                                 "required", "requireResidentKey": true,
                                 "userVerification": "required"}, "attestation": "none", ...}}
}
```

The options are the sign-up's (see `POST /v1/auth/passkey/begin`), for the user handle of the
user's existing passkeys (a fresh one when they have none), with `excludeCredentials` listing
every passkey the user already has (absent when none), so an authenticator holding one of them
refuses instead of making a duplicate. The ceremony is bound to the calling user, is valid for 5
minutes, and is finished once. Errors: `401 unauthorized`, `429 rate_limited` (counted with the
sign-in begins).

### `POST /v1/me/passkeys/finish`

Request (no other fields):

```json
{"ceremonyId": "4f0c...", "attestation": { <RegisterPublicKeyCredential> }}
```

Verifies the attestation against the ceremony and adds the passkey to the caller's account; from
then on either passkey signs in to it. `200` with the new identity, in `GET /v1/me`'s
`identities` shape:

```json
{"id": "019b...", "kind": "passkey", "name": "Agent Workspace account",
 "createdAt": "2026-11-01T12:00:00.000000Z", "lastUsedAt": null}
```

A ceremony that another user began, that a sign-in began (`POST /v1/auth/passkey/begin`), or that
is unknown, expired, or used is `400 ceremony_expired`. A malformed or unverifiable attestation,
or a passkey that already belongs to an account, is `401 credential_rejected`. Errors also: `400
invalid_request`, `401 unauthorized`, `429 rate_limited` (counted with the sign-in finishes).

### `DELETE /v1/me/identities/{id}`

Unlinks one of the caller's sign-in methods, by its `id` from `GET /v1/me`. `204` with no body.
An id that is not one of the caller's identities (another account's, an unknown one, or not a
UUID) is `404 not_found`. The account's only remaining identity is `409 last_identity`; of two
removals racing, at most one succeeds when they would together remove the last. Errors also:
`401 unauthorized`.

### `DELETE /v1/sessions/self`

Log out: deletes the presented token and nothing else. `204` with no body. The token is `401
unauthorized` from then on, but the device stays enrolled and **unrevoked**: a later sign-in that
sends its `deviceId` reuses it, and sync continues from where it was. To remove the device from
the account instead, use `DELETE /v1/devices/self`. Errors: `401 unauthorized`.

### `DELETE /v1/me`

Deletes the account (App Store guideline 5.1.1(v)). `204` with no body. In order:

1. An account in a shared org is refused, `409 shared_org`, before anything else.
2. Each Apple refresh token the account stores is decrypted and revoked at Apple. If any revoke
   fails, the request fails with `500 internal_error` and **nothing is deleted**; retry it.
3. In one transaction that first locks the user, the hub deletes the user's tokens, identities,
   and devices, every row of their personal org in every tenant table (threads, turns, the change
   log, and the rest), then the org and the user. An Apple ID linked between steps 2 and 3 is
   revoked too before the delete goes ahead.

Every token of the account is `401 unauthorized` afterwards, and its passkeys and Apple IDs can
sign up afresh. (Sign in with Apple is not built yet, so no account stores an Apple refresh token
today.) Errors also: `401 unauthorized`.

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

Revoke the calling device (remove it from the account): its token rows are deleted and
`devices.revoked_at` is set. To log out and keep the device, use `DELETE /v1/sessions/self`. Changes the
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
