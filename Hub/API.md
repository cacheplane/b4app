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
The token comes from `POST /v1/enroll` or a sign-in (`POST /v1/auth/passkey/finish`, `POST
/v1/auth/apple/native`, or `POST /v1/auth/handoff`), the only places it is ever shown; the hub stores only its SHA-256. Authentication happens before the request body is read, so an unauthenticated
request is refused without its body being consumed. A missing header, another scheme, a malformed
token, an unknown token, and a revoked device all answer the same `401 unauthorized`, so a caller
learns nothing about which it was.

The principal (org, user, device) comes only from the verified token. Nothing in a request body or
query can name a different one, and the wire `Change` carries no device id: the hub attributes
every change to the authenticated device.

### Request ids

Every response carries `X-Request-Id`: a UUIDv7 the hub mints per request, never a value a caller
supplied (nothing deployed in front of the hub strips the header, so an honoured inbound id would
let a client choose the id it is logged under). Every log line the request produces names that id
(see "Logging"), so an operator can go from a client's error to the hub's lines for it. A caller may
send its own `X-Request-Id`; when it is 1 to 64 printable ASCII characters without whitespace the
hub records it as `client_request_id` beside its own id, for correlation with the caller's logs,
and otherwise ignores it. The id is an opaque string to clients.

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
| 400 | `ceremony_expired` | request | A sign-in ceremony that is unknown, expired (5 minutes), already finished, of another kind or another user, or (for a sign-up) was begun while sign-up was closed; or a handoff that is unknown, expired (2 minutes), spent, or presented with the wrong verifier. The cases are indistinguishable. Begin again. |
| 400 | `invalid_request` | request | The body is not valid JSON for the endpoint (malformed JSON, an unknown or missing field, a wrong value type, a missing or wrong `Content-Type`); a `deviceName`, `platform`, or `fullName` that fails validation; a push token, environment, or bundle id that fails validation; a push with more than 1000 changes; a non-numeric `after`, `limit`, or `wait`; a link request that is not a WebSocket upgrade or whose `B4-Protocol` is not a whole number. |
| 401 | `unauthorized` | request | The bearer token is missing, malformed, unknown, or belongs to a revoked device. |
| 401 | `invalid_code` | request | The enrollment code is wrong, expired, or already used (the three are indistinguishable). |
| 401 | `credential_rejected` | request | A sign-in credential failed verification: a malformed WebAuthn response, a wrong origin or relying party, a bad signature, a passkey no account has, a user handle that is not the passkey's, a counter that went backwards, or a new passkey that already belongs to an account; any failed Apple check (see *Sign in with Apple*); a link's handoff at `POST /v1/auth/handoff`, or one presented by another account's device. Deliberately vague, except that a passkey sign-in whose credential no account has says `details.reason: "unknown_credential"` (see `POST /v1/auth/passkey/finish`). |
| 403 | `forbidden` | request | The device is authenticated but may not do this: `POST /v1/devices/self/push-token` from a device that is not `ios`. |
| 403 | `signup_closed` | request | A sign-up (a passkey `attestation`, or an Apple ID no account has) while the hub's sign-up policy is `closed`. |
| 403 | `step_up_required` | request | A change that needs a step-up (`POST /v1/me/passkeys/begin`, `POST /v1/me/apple`, `DELETE /v1/me/identities/{id}`, `DELETE /v1/me`) without a live grant in `B4-Step-Up`: none, unknown, expired, already used, or earned by another device or user (indistinguishable). `details.methods` lists the kinds of sign-in method the account can step up with, `passkey` before `apple`. See *Step-up*. |
| 404 | `not_found` | request | No such route, or a resource that does not exist or is not yours (including another account's identity id). |
| 405 | `method_not_allowed` | request | The route exists but not for that method. |
| 409 | `last_identity` | request | `DELETE /v1/me/identities/{id}` of the account's only sign-in method, which would leave it unable to sign in. Add another first. |
| 409 | `apple_linked` | request | `POST /v1/me/apple`, `/v1/me/apple/native`, or `/v1/me/apple/handoff` (or a link's callback) for an account that already has an Apple ID: an account links at most one. |
| 409 | `merge_refused` | request | `POST /v1/enroll` with a token whose account cannot be merged into the code's. `details.reason` says why, checked in this order: `same_account` (the token's org is the code's own: the phone is already in it, whichever user of that org it is), `shared_org` (a member of a shared org rather than the owner of a personal one), or `has_mac` (it has, or ever had, a `macos` device). It is absent when the hub cannot say (the token's user is gone). Nothing changes, and the code stays redeemable. |
| 409 | `shared_org` | request | `DELETE /v1/me` by a member of a shared (non-personal) org, such as an operator-seeded user; only the owner of a personal org can delete their account here. Nothing is revoked or deleted. |
| 409 | `relocated` | request | `GET /v1/devices/self/link` reached an instance other than the one serving this user's links; `details.instanceId` names that instance. No socket is opened. Retry at once, at most 3 times, then with the normal backoff (see *Link*, *More than one instance*). |
| 410 | `resync_required` | request | The pull cursor is older than the retention horizon: the hub has pruned the changes after it. Restore from `GET /v1/snapshot` (see *Horizon*). |
| 413 | `payload_too_large` | request | A push body over 32 MiB. (A change whose `value` is over 2 MiB is rejected per change instead; see `POST /v1/changes`.) |
| 429 | `rate_limited` | request | Too many sign-in requests from this client this minute (see *Sign-in*, *Rate limits*); a device opened too many relay links in a minute (the upgrade is refused before it happens); or a user minted an eleventh pairing code in an hour. Always with `details.retryAfterMs`; on the link it is also a `reply` error for a command over its limits (see *Link*, *Commands*). |
| 500 | `internal_error` | execution | Any unexpected failure; the cause is logged on the hub, never sent. |
| 503 | `not_ready` | execution | `/readyz`: the database is unreachable, migrations are pending, the relay probe failed (`details.relay: "failed"`), or this instance's heartbeat is stale (`details.instances: "stale"`). |
| 503 | `shutting_down` | execution | `/readyz` after SIGTERM. |
| 503 | `maintenance` | execution | A write (`POST /v1/enroll`, `POST /v1/pairing-codes`, `POST /v1/changes`, `POST /v1/devices/self/push-token`, `DELETE /v1/devices/self`, and the sign-in and account writes listed under "Maintenance mode") while the operator has paused writes; carries `Retry-After: 30`. See "Maintenance mode". |

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
| Other request bodies | 2 MiB (axum's default) | `POST /v1/enroll`, `POST /v1/auth/passkey/finish`, `PUT /v1/me/profile`, `POST /v1/me/passkeys/finish`, and the Apple routes |
| Sign-in begins | 20 per client IP per minute | `POST /v1/auth/passkey/begin`, `POST /v1/me/passkeys/begin`, `POST /v1/auth/apple/begin`, `GET /v1/auth/apple/start`, and `POST /v1/me/apple`, together; over it, `429 rate_limited` |
| Sign-in finishes | 10 per client IP per minute | `POST /v1/auth/passkey/finish`, `POST /v1/me/passkeys/finish`, `POST /v1/auth/apple/native`, `POST /v1/auth/apple/callback`, `POST /v1/auth/handoff`, `POST /v1/me/apple/native`, and `POST /v1/me/apple/handoff`, together, counted before the token is checked or the body read; over it, `429 rate_limited` |
| Full name | 1 to 200 characters after trimming | `PUT /v1/me/profile` |
| Ceremony lifetime | 5 minutes, single use | a `ceremonyId` from a begin |
| Handoff lifetime | 2 minutes, single use | the code in the web flow's redirect |

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

Readiness: the database answers, every migration is applied, the relay serves a link, and this
instance's heartbeat is fresh. No authentication. This is what the container `HEALTHCHECK` and the
load balancer's health check call.

`200`:

```json
{"ok": true, "migrations": "current", "minClientProtocol": 1, "relay": "ok", "instances": "ok"}
```

`relay` is an in-process probe: the hub runs its own link task over an in-memory socket with a
probe identity that never registers (it is never online, never in a `presence` frame, and never
watches), and expects `hello`, `presence`, and a `pong` to a `ping` within 2 seconds. No device is
minted and no row is written. `instances` is `"stale"` once this instance has not written its
heartbeat for the liveness window (20 seconds; see *More than one instance*), because the other
instances already count it dead and may take its users. Either failure is `503 not_ready` with
`details.relay` and `details.instances` beside the code. Every `/readyz` answer, success or not,
carries `Set-Cookie: b4hub-instance=<this instance's id>; Path=/; Max-Age=3600; Secure; HttpOnly`.

While writes are paused (see "Maintenance mode") the body also carries `"maintenance":
"read_only"`; the status stays `200`, because reads are still served.

`503 not_ready` when the database is unavailable, migrations are pending, the relay probe failed, or
the heartbeat is stale; `503 shutting_down`
once SIGTERM has been received (see "Shutdown").

### `POST /v1/enroll`

Exchange a one-time enrollment code for a device token. The code is the credential; the
`Authorization` header is optional (see *Merging a phone-only account* below). The operator mints a code with `b4hub enroll --user <username>`; it is eight
characters from `BCDFGHJKLMNPQRSTVWXZ23456789`, valid for ten minutes, single-use, and matched
case-insensitively.

Request (`code`, `deviceName`, and `platform` required; `deviceId` and `candidateDeviceIds`
optional; no others allowed):

```json
{"code": "ABCD2345", "deviceName": "Brian's MacBook Pro", "platform": "macos",
 "deviceId": "0198...", "candidateDeviceIds": ["0198..."]}
```

- `deviceName`: 1 to 200 characters after trimming.
- `platform`: `macos`, `ios`, or `cli`.
- `deviceId` and `candidateDeviceIds`: the devices the client already has, with the same shape,
  limits, and rule as a sign-in's `device` object (`POST /v1/auth/passkey/finish`): the first
  candidate, `deviceId` counting first, that is an unrevoked device of the **code's** user on the
  same platform is reused, renamed, and its earlier tokens are deleted; otherwise a new device is
  made. So a Mac or phone that logged out and rejoins with a code keeps its device, and the rows it
  synced keep their owner. More than 32 candidates, or an id that is not a UUID, is
  `400 invalid_request`. A hub older than these fields refuses them the same way.

All of them are validated before the code is redeemed, so a malformed request does not use the code
up.

`200`:

```json
{
  "deviceId": "0198...",
  "token": "<43 characters, base64url>",
  "org": {"slug": "cacheplane", "name": "cacheplane"},
  "user": {"username": "blove", "displayName": "Brian Love"}
}
```

`token` appears in this response and nowhere else; keep it in the Keychain. `deviceId` is the
reused device's id when one was reused, a new one otherwise. Errors:
`400 invalid_request`, `401 invalid_code`, `401 unauthorized` and `409 merge_refused` (below),
`503 maintenance`.

**Merging a phone-only account.** A phone already signed in to an account of its own (one it
signed up with, which has never had a Mac) sends that account's token,
`Authorization: Bearer <phone token>`, so pairing does not leave the person with two accounts. In
one transaction the hub claims the code, moves every identity (passkeys, Apple IDs) of the
token's account to the code's user, deletes that account's devices (so the phone's old token
stops working at once), tokens, relay link claim, user, and personal org (which holds no synced
rows: only a Mac writes them), and enrolls the device under the code's account (reusing one of the
code's user's devices by the rule above; a device of the token's account is never reused, since
candidates match only the code's user). Once it
commits, the old account's relay links on the instance that served the request close with code
4001. The answer is the same `200`
as above, for the code's account. If any step fails nothing has changed: a wrong, expired, or used
code is `401 invalid_code` and the phone's account and token are untouched.

- A header that is present but not a valid token (another scheme, malformed, unknown, revoked) is
  `401 unauthorized`, before the code is looked at.
- A token whose account is in the code's own org, belongs to a shared org, or has (or had) a
  `macos` device is `409 merge_refused` with `details.reason` `same_account`, `shared_org`, or
  `has_mac`, and the code stays redeemable. The code is checked first: a wrong, expired, or used
  one is `401 invalid_code` whatever the token.
- Without the header, enrollment is exactly as before.

### `POST /v1/pairing-codes`

A joined Mac mints a code that pairs a phone. Bearer auth; no body. Only a `macos` device may
mint: an `ios` or `cli` caller gets `404 not_found`, as if the route did not exist. The code is an
ordinary enrollment code (same alphabet, hashing, and case-insensitive match) that expires in
five minutes instead of ten and is single-use. The phone redeems it at `POST /v1/enroll` with
`platform: "ios"` and becomes a device of the same user. Redeemed as any other platform it is
`401 invalid_code` and stays redeemable, so a code's holder can never take over the Mac's own
device through `candidateDeviceIds`. The hub remembers which Mac minted it.

`200`:

```json
{"code": "ABCD2345", "expiresAt": "2026-11-01T12:05:00.000000Z", "hubURL": "https://hub.example.com/"}
```

`hubURL` is `B4HUB_PUBLIC_URL`, and is absent when that is not set. Neither the code nor its hash
is logged.

A user may mint 10 codes in any hour. The eleventh is `429 rate_limited` with
`details.retryAfterMs`, the milliseconds until the tenth most recent mint is an hour old; the
refused request stores nothing. Codes of different users are limited separately.

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
and every client shares its limit. Sign in with Apple needs `B4HUB_APPLE_TEAM_ID`,
`B4HUB_APPLE_KEY_ID`, `B4HUB_APPLE_PRIVATE_KEY` (the `.p8` key's PEM contents, not a path), and
`B4HUB_APPLE_AUDIENCES` (the comma-separated client ids an identity token may be for: the iOS
bundle id and the Services ID), all set or none (any other combination exits 2, as does a key that
does not sign). Without them every Apple route below answers `404 not_found`. The web flow (the
Mac's) also needs `B4HUB_APPLE_SERVICES_ID`, the Services ID it signs in with (one of the
audiences), and `B4HUB_PUBLIC_URL`, under which Apple posts back; without either only the native
flow is offered. With `B4HUB_APPLE_SERVICES_ID`, `B4HUB_APPLE_CALLBACK_SCHEME` is required: the one
app URL scheme the web flow hands results back to, the flavour this hub serves (`b4app` for prod,
`b4app-beta` for beta, `b4app-local` for local). It exits 2 when it is missing, not one of those
three, or set without `B4HUB_APPLE_SERVICES_ID`. `B4HUB_APPLE_BASE_URL` (tests only; default
`https://appleid.apple.com`) moves every Apple endpoint and the issuer identity tokens must name.
A secret's variable holds the value itself, never a path (`B4HUB_APPLE_PRIVATE_KEY` is the PEM
contents). `seed` and `enroll` read none of these.

**Secrets from files.** For Docker and Kubernetes secrets mounted as files, each of
`B4HUB_SECRET_KEY`, `B4HUB_APPLE_TEAM_ID`, `B4HUB_APPLE_KEY_ID`, and `B4HUB_APPLE_PRIVATE_KEY` has a
`_FILE` form (`B4HUB_SECRET_KEY_FILE`, and so on) that names a file holding the value; so do
`DATABASE_URL` and `DATABASE_ADMIN_URL` (`DATABASE_URL_FILE`, `DATABASE_ADMIN_URL_FILE`). A
variable and its `_FILE` form are mutually exclusive: setting both exits 2, naming both. A `_FILE`
that is missing, a directory, or not UTF-8 exits 2 naming the `_FILE` variable; no error ever
carries the file's contents. One trailing line ending (`\n` or `\r\n`) is removed from the file and
nothing else is, so the PEM keeps its inner newlines. For Sign in with Apple's all-or-none rule, a
`_FILE` form counts as setting its variable. The values themselves are validated exactly as when
they come from the environment.

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
`B4HUB_LOG` directive, module-qualified or not, gets past it. The Apple routes never log an
identity token, authorization code, client secret, refresh token (sealed or not), handoff,
verifier, or Apple ID (`sub`); a failed check logs `Apple verification failed` with a fixed reason.

#### `GET /v1/auth/config`

What this hub offers, so a client hides the rest. Not rate limited. `200`:

```json
{"passkeys": {"rpId": "b4.run"}, "apple": {"native": true, "web": true}, "signup": "open"}
```

`apple.native` is true when the `B4HUB_APPLE_*` set configures Sign in with Apple; `apple.web`
when, in addition, `B4HUB_APPLE_SERVICES_ID` and `B4HUB_PUBLIC_URL` are set.

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
  "device": {"deviceName": "Brian's MacBook Pro", "platform": "macos", "deviceId": "0198...",
             "candidateDeviceIds": ["0198..."]}
}
```

- `device.deviceName` and `device.platform` are validated as for `POST /v1/enroll`.
- `device.deviceId` (optional): on a sign-in, when it names an unrevoked device of the same user
  on the same platform, that device is reused, renamed, and its earlier tokens are deleted;
  otherwise a new device is made. A sign-up always makes a new device.
- `device.candidateDeviceIds` (optional): up to 32 more device ids, for a client that cannot know
  which account a sign-in is for (a Mac that has signed in to several accounts sends the device it
  has with each). `deviceId` counts as the first candidate; the first candidate that passes the rule
  above is reused, and the others are passed over. More than 32, or one that is not a UUID, is
  `400 invalid_request`.
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
  "userId": "0197...",
  "token": "<43 characters, base64url>",
  "org": {"slug": "o-k2m4q7xz", "name": "My Org"},
  "user": {"username": "u-a3b9c2d7", "displayName": ""},
  "needsOnboarding": true
}
```

`userId` is the user's id (`users.id`), which never changes and is never reused; a client keys its
local accounts on it. `needsOnboarding` is true until the user has given a full name. The token
appears here and nowhere else.

Validation happens before the ceremony is taken, so a malformed request does not use it up. Of
two finishes of one ceremony racing, exactly one succeeds; the other is `ceremony_expired`.
Errors: `400 invalid_request` (the body's shape, both or neither response, a bad device),
`403 signup_closed` (an attestation while sign-up is closed, checked before the ceremony is
taken), `400 ceremony_expired`, `401 credential_rejected`, `429 rate_limited`.

A refused **assertion** whose credential id no identity holds (never registered, or its account
was deleted) is the only `credential_rejected` with a reason: `details.reason` is
`"unknown_credential"`, so the app can tell the password manager to forget that passkey:

```json
{"error": {"kind": "request_error", "message": "the credential could not be verified",
           "details": {"code": "credential_rejected", "reason": "unknown_credential"}}}
```

Every other refusal (a malformed response, a wrong origin or relying party, a bad signature, a
user handle that is not the passkey's, a counter that went backwards, a refused attestation) carries
no reason, so a client never forgets a passkey the hub still holds. Credential ids are random, so
the reason tells a caller nothing it could use to find an account.

#### Sign in with Apple

"Continue with Apple" has two flows that end like a passkey sign-in: the iPhone's **native** flow
(Apple's sheet, then `POST /v1/auth/apple/native`) and the Mac's **web** flow (Apple's authorize
page in a browser session, Apple's form post back to the hub, then a one-time handoff to the app).
Both begin with `POST /v1/auth/apple/begin`.

- **The nonce.** A ceremony holds a random `nonce`. Apple is always handed its lowercase hex
  SHA-256 (the native app passes `sha256_hex(nonce)` as the request's nonce; the web flow's start
  URL carries it), and the identity token's `nonce` claim must equal exactly that hash.
- **Verifying an identity token.** The key the token's `kid` names in Apple's key set
  (`<base>/auth/keys`), which decides the algorithm: Apple publishes RSA keys (`RS256`); an EC
  P-256 key (`ES256`) is accepted too, and a header `alg` that is not its key's is refused. The key
  set is cached and fetched again only for an unknown `kid`, at most once a minute. Then `iss`
  must be `https://appleid.apple.com` (the base URL), `aud` one of `B4HUB_APPLE_AUDIENCES` (the
  Services ID, for the web flow), `exp` not past (60 s leeway), and the nonce as above.
- **The code exchange** (`<base>/auth/token`) uses a client secret the hub signs for each call:
  an ES256 JWT with `kid` = `B4HUB_APPLE_KEY_ID`, `iss` = the team id, `sub` = the client id in use
  (the token's `aud`: the bundle id natively, the Services ID on the web), `aud` =
  `https://appleid.apple.com`, and five minutes to `exp`. Apple's answer must carry an identity
  token, verified like any other (without the nonce) and for the same Apple ID, so a code for
  another Apple ID is refused.
- **Accounts.** The account is found by the token's `sub`. A new `sub` signs up while sign-up is
  open (a personal org, as a passkey sign-up makes); while it is closed it is `403 signup_closed`,
  checked **before** the code is exchanged. Apple's email is stored with the identity (it is the
  identity's `name` in `GET /v1/me`) but never used to find or merge accounts. On a first sign-up
  with a name, the user's `displayName` is that name, the onboarding prefill; `needsOnboarding`
  stays true until `PUT /v1/me/profile`. In the web flow all of this happens when the app redeems
  the handoff, never at Apple's callback.
- **Linking.** An account links at most one Apple ID (`409 apple_linked` otherwise).
- **The refresh token** from the exchange is stored sealed (AES-256-GCM under `B4HUB_SECRET_KEY`,
  a random 96-bit nonce first, the identity's id as associated data) with the client id it was
  issued to, so deleting the account can revoke it. A sign-in replaces it with the newest.
- **Errors.** Every failed check (signature, key, issuer, audience, expiry, nonce, a refused or
  mismatched code, an Apple ID another account holds) is `401 credential_rejected`, deliberately
  the same; so is Apple being unreachable.

##### `POST /v1/auth/apple/begin`

Begins an Apple ceremony (valid 5 minutes, finished once). The body is empty (or `{}`) for the
native flow; the web flow sends both fields:

```json
{"verifierHash": "<64 lowercase hex characters>", "scheme": "b4app"}
```

- `verifierHash` is the lowercase hex SHA-256 of a random verifier (43 to 128 characters of
  `A-Z a-z 0-9 - . _ ~`) the app keeps for `POST /v1/auth/handoff`.
- `scheme` is the app's URL scheme, one of `b4app`, `b4app-beta`, `b4app-local`, and it must be
  this hub's `B4HUB_APPLE_CALLBACK_SCHEME`: a hub hands results back only to the flavour it
  serves, so no caller can have a handoff sent to an app the person did not start from. The
  callback redirects only to that scheme, never to one from a later request.

`200`: `{"ceremonyId": "5b0f...", "nonce": "<43 characters>"}`. Errors: `400 invalid_request` (one
field without the other, a scheme off the list, a malformed hash, or another flavour's scheme,
whose message names the scheme this hub serves; no ceremony is made), `404 not_found` (no Apple,
or the web flow asked of a hub without it), `429 rate_limited` (a begin).

##### `POST /v1/auth/apple/native`

The iPhone's sheet returned. Request:

```json
{
  "ceremonyId": "5b0f...",
  "identityToken": "<Apple's JWT>",
  "authorizationCode": "<Apple's code>",
  "fullName": "Brian Love",
  "device": {"deviceName": "Brian's iPhone", "platform": "ios", "deviceId": "0198..."}
}
```

`fullName` (optional; Apple gives it on the first sign-in only) is trimmed, at most 200
characters. `device` is as for the passkey finish. The token is verified against the ceremony,
the code exchanged as the token's `aud`, and the account signed in or up; `200` is the session
shape of `POST /v1/auth/passkey/finish`. Validation happens before the ceremony is taken. Errors:
`400 invalid_request`, `400 ceremony_expired` (also a web or link ceremony), `401
credential_rejected`, `403 signup_closed`, `404 not_found`, `429 rate_limited` (a finish).

##### `GET /v1/auth/apple/start?ceremony=<ceremonyId>`

Opened by the Mac in its browser session for a web ceremony. `302` to Apple's authorize page,
`<base>/auth/authorize?client_id=<Services ID>&redirect_uri=<B4HUB_PUBLIC_URL>/v1/auth/apple/callback&response_type=code%20id_token&response_mode=form_post&scope=name%20email&state=<ceremonyId>&nonce=<sha256_hex(nonce)>`.
It does not use the ceremony up, so a reloaded page starts again. Errors: `400 invalid_request`
(no `ceremony`, not a UUID, or any other parameter), `400 ceremony_expired` (unknown, expired,
finished, or a native ceremony), `404 not_found` (no web flow), `429 rate_limited` (a begin).

##### `POST /v1/auth/apple/callback`

Apple's `application/x-www-form-urlencoded` form post, sent by the person's browser: `state` (the
ceremony id), `code`, `id_token`, on the first sign-in `user` (JSON whose `name.firstName` and
`name.lastName` become the name), or `error`. Fields the hub does not read are ignored (Apple may
add some); a repeated one is `400 invalid_request`. The ceremony is taken and the identity token
verified (signature, issuer, the Services ID as audience, expiry, nonce). **Nothing else happens
here**: no user, org, identity, or device is created and the code is not exchanged, so a browser
that is not the app's (a start URL forwarded to someone else, a leaked ceremony id) achieves
nothing. The hub records a handoff (2 minutes, single use) carrying the verified Apple ID, its
email and (on a first sign-in) name, the client id, and the authorization code, all sealed with
`B4HUB_SECRET_KEY` with the handoff code's hash as associated data; everything happens when the
app redeems it with its verifier. For a link ceremony, an Apple ID another account holds is
refused here (`credential_rejected`), as is a link to an account that already has an Apple ID
(`apple_linked`); for a sign-in, a new Apple ID while sign-up is closed (`signup_closed`, checked
again at the redemption). The answer is a `302` to the hub's scheme
(`B4HUB_APPLE_CALLBACK_SCHEME`):

- `<scheme>://auth?handoff=<43 characters>` on success: a sign-in's goes to `POST
  /v1/auth/handoff`, a link's to `POST /v1/me/apple/handoff`;
- `<scheme>://auth?error=<code>` once the ceremony is known: `cancelled` (Apple's
  `user_cancelled_authorize`), `credential_rejected`, `signup_closed`, `apple_linked`, or
  `internal_error`.

A post whose `state` is missing is `400 invalid_request`; one whose ceremony is unknown, spent, or
not a web ceremony is `400 ceremony_expired` as JSON, having nowhere to redirect. Also `404
not_found` (no web flow) and `429 rate_limited` (a finish).

##### `POST /v1/auth/handoff`

The Mac hands over the redirect's code with its verifier:

```json
{"handoff": "<the code>", "verifier": "<the verifier>",
 "device": {"deviceName": "Brian's MacBook Pro", "platform": "macos", "deviceId": "0198..."}}
```

The hub matches the code's hash and the verifier's SHA-256 against a sign-in's handoff, once,
then exchanges the code (Apple's answer must carry an identity token for the same Apple ID),
signs the Apple ID's account in or signs it up (`403 signup_closed` while sign-up is closed), and
answers the session shape for `device` (as for the passkey finish, `deviceId` and
`candidateDeviceIds` included). A wrong verifier is answered exactly like an unknown, expired, or
spent code, `400 ceremony_expired`, and leaves the handoff redeemable by its rightful
holder; of two redemptions racing, exactly one succeeds. **A link's handoff is `401
credential_rejected` here** and is not used up (it belongs at `POST /v1/me/apple/handoff`). A
refused exchange is `401 credential_rejected` and the handoff is spent. Errors also: `400
invalid_request` (validated first), `404 not_found`, `429 rate_limited` (a finish).

### `GET /v1/me`

The authenticated device, the org and user it belongs to, and the account's sign-in methods.
`200`:

```json
{
  "deviceId": "0198...",
  "userId": "0197...",
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
  the answer; `userId` (the same id a sign-in answers), `user.fullName`, `onboarded`, and
  `identities` were added with sign-in.
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
operator-enrolled user gets their first one). No body; needs a step-up grant (see *Step-up*). `200`:

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
refuses instead of making a duplicate. The ceremony is bound to the calling user and device, is
valid for 5 minutes, and is finished once. Errors: `401 unauthorized`, `403 step_up_required`,
`429 rate_limited` (counted with the sign-in begins).

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

A ceremony that another user or device began, that a sign-in began (`POST /v1/auth/passkey/begin`),
or that is unknown, expired, or used is `400 ceremony_expired`. A malformed or unverifiable attestation,
or a passkey that already belongs to an account, is `401 credential_rejected`. Errors also: `400
invalid_request`, `401 unauthorized`, `429 rate_limited` (counted with the sign-in finishes).

### `POST /v1/me/apple`

Begins linking an Apple ID to the caller's account (Settings, "Connect Apple ID"). The body is
`POST /v1/auth/apple/begin`'s: empty for the iPhone's native flow, `verifierHash` and `scheme` for
the Mac's web flow; so is the answer, `{"ceremonyId", "nonce"}`. The ceremony records the caller
and can finish only a link. On the web the Mac then opens `GET /v1/auth/apple/start`, Apple posts
to the callback, and the Mac redeems the handoff at `POST /v1/me/apple/handoff`. An account links
at most one Apple ID ("Connect Apple ID" shows only when there is none): with one already, this is
`409 apple_linked`, checked before the step-up grant this route needs (see *Step-up*). (Merging a
phone-only account on pairing moves its identities without that check.) Errors: as the begin,
plus `401 unauthorized`, `403 step_up_required`, and `409 apple_linked`.

### `POST /v1/me/apple/handoff`

Finishes a web link, with the device's token:

```json
{"handoff": "<the code>", "verifier": "<the verifier>"}
```

The handoff must be a link's, begun by **this** account: one presented by a device of another
account, or a sign-in's handoff, is `401 credential_rejected` and stays redeemable where it
belongs; a wrong verifier, or an unknown, expired, or spent code, is `400 ceremony_expired`. Then
the code is exchanged and the Apple ID added; `200` is the new identity, as `POST
/v1/me/passkeys/finish` answers one. An Apple ID already on this account answers its identity;
one on another account is `401 credential_rejected`, and any other while the account has one is
`409 apple_linked`, both before the code is exchanged. Errors also: `400 invalid_request`, `401
unauthorized`, `404 not_found`, `429 rate_limited` (a finish).

### `POST /v1/me/apple/native`

Finishes a native link against a ceremony from `POST /v1/me/apple` the same user began:

```json
{"ceremonyId": "5b0f...", "identityToken": "<Apple's JWT>", "authorizationCode": "<Apple's code>"}
```

`200` is the new identity, as `POST /v1/me/passkeys/finish` answers one. An Apple ID already on
this account answers its identity; one on another account is `401 credential_rejected`, and any
other while the account has one is `409 apple_linked`, both before the code is exchanged. Errors also: `400 invalid_request`, `400 ceremony_expired` (another user's
ceremony, a sign-in ceremony, or a web one), `401 unauthorized`, `404 not_found`, `429
rate_limited` (a finish).

### Step-up

Adding a sign-in method (`POST /v1/me/passkeys/begin`, `POST /v1/me/apple`), removing one
(`DELETE /v1/me/identities/{id}`), and deleting the account (`DELETE /v1/me`) need more than the
device token: a **step-up grant**, proof that the signed-in user finished a passkey or Apple
assertion on this device moments before (D-150). The change carries it in a header:

```
Authorization: Bearer <device token>
B4-Step-Up: <grant>
```

A grant is earned from one of the routes below and answers, from every finish:

```json
{"stepUp": "<43 characters>", "expiresAt": "2026-11-02T12:02:00.000000Z"}
```

- It is valid for **2 minutes**, for **one** change: the first change that presents it takes it,
  whether the change then succeeds or fails (a failed Apple revoke, `500`, needs a new one).
- It is bound to the user and the **device** whose token earned it; another device's token,
  another user's, or no grant at all is `403 step_up_required`. The hub stores only its SHA-256,
  and never logs it.
- Each change's refusals that need no grant come first and spend none: `apple_linked` at `POST
  /v1/me/apple`, `not_found` and `last_identity` at `DELETE /v1/me/identities/{id}`, `shared_org`
  at `DELETE /v1/me`.
- An add is gated at its begin: the finish (`POST /v1/me/passkeys/finish`, `POST
  /v1/me/apple/native`, `/handoff`) needs the begin's ceremony, which records the device and is
  `ceremony_expired` from any other.
- An account with **no** sign-in method (operator-enrolled, never signed in) has nothing to step
  up with and makes these changes on its token alone.

The step-up routes need the device token, count as sign-in begins and finishes for the rate
limits, and are paused in maintenance.

#### `POST /v1/me/step-up/passkey/begin`

No body. `200`:

```json
{"ceremonyId": "0335...", "authentication": {"publicKey": {"allowCredentials": [{"id": "...",
 "type": "public-key"}], "challenge": "...", "rpId": "b4.run", "timeout": 300000,
 "userVerification": "required"}}}
```

Assertion options for the caller's own passkeys (`allowCredentials` lists every one; user
verification required). The ceremony records the user and the device, lives 5 minutes, and is
finished once. An account with no passkey is `404 not_found`. Errors also: `401 unauthorized`,
`429 rate_limited`.

#### `POST /v1/me/step-up/passkey/finish`

```json
{"ceremonyId": "0335...", "assertion": { <PublicKeyCredential> }}
```

Verifies the assertion against a step-up this device began, with one of the caller's passkeys,
updates its counter, and answers the grant. Another user's or device's ceremony, a sign-in
ceremony, or an unknown, expired, or used one is `400 ceremony_expired`; a malformed or
unverifiable assertion, or another account's passkey, is `401 credential_rejected`. Errors also:
`400 invalid_request`, `401 unauthorized`, `429 rate_limited`.

#### `POST /v1/me/step-up/apple`

Begins a step-up with the caller's own Apple ID. The body and the answer are `POST
/v1/auth/apple/begin`'s: empty for the iPhone's native flow, `verifierHash` and `scheme` for the
Mac's web flow, which then opens `GET /v1/auth/apple/start` and hands back through the callback as
a link does. An account with no Apple ID, or a hub without Sign in with Apple, is `404 not_found`.

#### `POST /v1/me/step-up/apple/native`

```json
{"ceremonyId": "6d4c...", "identityToken": "<Apple's JWT>"}
```

Verifies the identity token against a native step-up this device began, as the native sign-in
does, and that its Apple ID is the caller's own; answers the grant. No authorization code is sent or
exchanged, so Apple keeps no new grant. Another user's or device's ceremony, or a web one, is `400
ceremony_expired`; another Apple ID, or any failed Apple check, is `401 credential_rejected`.

#### `POST /v1/me/step-up/apple/handoff`

```json
{"handoff": "<the code>", "verifier": "<the verifier>"}
```

Redeems a web step-up's handoff, once, from the device that began it, and answers the grant. The
callback already refused (`?error=credential_rejected`) an Apple ID that is not the caller's, and
the redemption checks it again. A handoff of a sign-in or a link, or presented by another device or
account, is `401 credential_rejected`; a wrong verifier, or an unknown, expired, or spent code, is
`400 ceremony_expired`. The code is not exchanged.

### `DELETE /v1/me/identities/{id}`

Unlinks one of the caller's sign-in methods, by its `id` from `GET /v1/me`, with a step-up grant
(see *Step-up*). `204` with no body. An id that is not one of the caller's identities (another
account's, an unknown one, or not a UUID) is `404 not_found`. The account's only remaining identity
is `409 last_identity`; of two removals racing, at most one succeeds when they would together
remove the last. Both are checked before the grant is taken and before anything is revoked.

An Apple ID whose refresh token the hub stores is revoked at Apple first, as `DELETE /v1/me`
revokes one (decrypted, then `<base>/auth/revoke` as the client id it was issued to), and only
then is the identity deleted, so unlinking never leaves a grant at Apple that the hub can no longer
revoke. A token that does not open, or a revoke that fails, removes nothing: the request fails with
`500 internal_error`; retry it. A hub without Sign in with Apple cannot revoke, so unlinking an
Apple ID that holds a token fails the same way. A sign-in that replaces the token meanwhile has the
new one revoked too before the delete. Errors also: `401 unauthorized`, `403 step_up_required`.

### `DELETE /v1/sessions/self`

Log out: deletes the presented token and nothing else. `204` with no body. The token is `401
unauthorized` from then on, but the device stays enrolled and **unrevoked**: a later sign-in that
sends its `deviceId` reuses it, and sync continues from where it was. To remove the device from
the account instead, use `DELETE /v1/devices/self`. The device's push token is kept, but a device
with no session is not notified (see *When the hub notifies*) until it signs in again. Errors: `401
unauthorized`.

### `DELETE /v1/me`

Deletes the account (App Store guideline 5.1.1(v)), with a step-up grant (see *Step-up*). `204`
with no body. In order:

1. An account in a shared org is refused, `409 shared_org`, before anything else; then the grant
   is taken (`403 step_up_required` without a live one).
2. Every Apple refresh token the account stores is decrypted first; only if all of them open is
   each revoked at Apple (`<base>/auth/revoke`, as the client id it was issued to, with a fresh
   client secret). A token that does not open revokes nothing, and a failed revoke deletes
   nothing: either way the request fails with `500 internal_error`; retry it. A hub without
   Sign in with Apple cannot revoke, so an account holding a token fails the same way.
3. In one transaction that first locks the user, the hub deletes the user's tokens, identities,
   and devices, every row of their personal org in every tenant table (threads, turns, the change
   log, and the rest), then the org and the user. An Apple ID linked between steps 2 and 3 is
   revoked too before the delete goes ahead.

The same transaction deletes the user's relay link claim (`user_links`). Once it commits, every
token of the account is `401 unauthorized`, and every relay link of the account on the instance
that served the request is closed with code 4001 (device revoked) at once; its passkeys and Apple
IDs can sign up afresh. Errors also: `401 unauthorized`, `403 step_up_required`.

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
immediately; the next request with it is `401 unauthorized`. A pairing code the device minted
that is still unused is withdrawn with it (redeeming it is then `401 invalid_code`). If the device
has an open link (see *Link*), the hub closes it with code 4001. Errors: `401 unauthorized`.

### `POST /v1/devices/self/push-token`

A phone registers the APNs token the hub notifies it at. One row per device, replaced on every call.
Registering a token removes it from any other device of the org that still holds it (a phone that
enrolled again while the hub kept its old device), so no phone is told twice. The phone sends it
each time the system hands it a token while it is signed in, and after each sign-in.

Request (all three fields required, no other field allowed):

```json
{"token": "ab12...", "environment": "sandbox", "bundleId": "com.cacheplane.b4app"}
```

- `token`: 32 to 512 hexadecimal characters.
- `environment`: `sandbox` from the Simulator and from device builds signed with a development
  profile, `production` from TestFlight and App Store builds.
- `bundleId`: the app's bundle identifier, `^[A-Za-z0-9][A-Za-z0-9.-]{0,154}$`. It comes from the
  phone, so the hub needs no per-flavour configuration.

`204` with no body. Errors, in the order the hub checks them: `401 unauthorized`; `503
maintenance` while writes are paused; `400 invalid_request` for a malformed body, a missing or
unknown field; `403 forbidden` when the device is not an `ios` device; then `400 invalid_request`
for a field that fails the rules above. The token is never logged.

#### When the hub notifies

The hub decides inside the `POST /v1/changes` transaction, from the rows the batch applied, and
notifies the user's `ios` devices that are not revoked, hold a session (an unrevoked device token),
have a push token, and are not the one whose push caused the change:

- A `runtimeRequests` row whose `state` is `pending` notifies, whatever its age: kinds
  `command_approval`, `file_change_approval`, `tool_permission`, and `unknown` say "Waiting for
  your approval"; `user_question` and `elicitation` say "Has a question for you".
- A `turns` row whose `status` is `terminal` notifies when its `outcome` is `completed`
  ("Replied") or `failed` ("Turn failed"). `cancelled` never notifies, and a terminal turn with no
  outcome yet waits for the batch that sets it. A turn notifies only when its `updatedAt` is
  within 10 minutes of the hub's clock, so a Mac's first join does not flood the phone with
  history.
- Once per request id or turn id: the decision is written to a ledger (`notifications_sent`) in the
  same transaction, whether or not a sender is configured or the phone has a token, so a retried
  batch or a later update to the same row notifies nobody twice, and delivery is at most once.

The same transaction withdraws what is over: a notified request that is no longer `pending`
(answered or expired), a notified turn that its thread's `readTurnId` now covers, and everything
notified in a thread that was deleted. Each is withdrawn once (the ledger's `withdrawn_at`), to the
same phones as the alert, the one whose push caused it included.

Alerts and withdrawals are sent after the commit, on a task of their own: the push response never
waits on delivery, and a failed delivery is logged (device id, notification keys, and APNs's
status, `reason`, and `apns-id`; never the token, the title, or the provider token) and dropped.

#### Push payload

```json
{
  "aps": {
    "alert": {"title": "Fix the build", "body": "Waiting for your approval"},
    "sound": "default",
    "badge": 2,
    "content-available": 1,
    "thread-id": "thread-1"
  },
  "threadId": "thread-1",
  "reason": "approval",
  "key": "request:request-1"
}
```

`title` is the thread's title (`Untitled thread` when it has none), cut to 100 characters.
`body` is exactly one of `Waiting for your approval`, `Has a question for you`, `Replied`, or
`Turn failed`; it never carries transcript, command text, or paths. `reason` is `approval`,
`question`, `replied`, or `failed`. The payload carries no URL: the app builds
`<its scheme>://thread/<threadId>` itself. `key` is `request:<id>` or `turn:<id>`, the name a
withdrawal uses. `badge` is the number of the user's threads that need them (not archived or
deleted, in the needs-input or unread band), computed after the whole push.

A withdrawal is a background push naming the keys to remove, with no alert, sound, or badge:

```json
{"aps": {"content-available": 1}, "withdraw": ["request:request-1", "turn:turn-7"]}
```

#### Senders

`B4HUB_PUSH_SENDER` chooses how `serve` delivers:

- `none` (the default, also when unset): nothing is sent.
- `spool`: each alert and withdrawal is written to `B4HUB_PUSH_SPOOL_DIR` (required; created if missing)
  as `<unix ms>-<uuid>.apns`, the payload above (or the withdrawal) plus the `Simulator Target Bundle` key set to the
  phone's `bundleId`, which is what `xcrun simctl push booted - < file` reads. The file is written
  under a hidden `.tmp` name and renamed when complete, so a watcher never reads half a file.
  The Compose file sets this up and mounts the directory at `B4HUB_PUSH_SPOOL_HOST_DIR` (default
  `Hub/push-spool/`).
- `apns`: Apple Push Notification service over HTTP/2 and TLS. Needs `B4HUB_APNS_KEY_ID`,
  `B4HUB_APNS_TEAM_ID` (each 10 uppercase letters and digits), and `B4HUB_APNS_PRIVATE_KEY` (the
  `.p8` file's PEM contents), each also as `NAME_FILE`; `serve` refuses to start (exit 2, naming
  the variable, never echoing the key) when one is missing or the key does not sign.
  - A `sandbox` token is sent to `api.sandbox.push.apple.com`, a `production` token to
    `api.push.apple.com`, as `POST /3/device/<token>` on one kept-open connection per endpoint.
  - Authentication is a provider token: an ES256 JWT with `kid` the key id, `iss` the team id,
    and `iat`, reused for 50 minutes.
  - Headers: `apns-topic` is the token's `bundleId`; an alert is `apns-push-type: alert`,
    `apns-priority: 10`, `apns-collapse-id` its `key`, expiring after 4 hours; a withdrawal is
    `background`, priority `5`, expiring after 15 minutes.
  - Apple's answers: `410`, `400 BadDeviceToken`, and `400 DeviceTokenNotForTopic` delete the
    phone's push token (unless it registered a newer one meanwhile), so it is told nothing until it
    registers again. `403 ExpiredProviderToken` or `InvalidProviderToken` re-mints the JWT and
    tries once more; `429`, a `5xx`, or no answer (10 s to connect, 15 s per request) tries once
    more after 500 ms. Anything else is logged and dropped.

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
- `cannot_clear`: the change is an `update` that sets `threads.userDeletedAt` to null (or omits its
  value), from any device. A thread's delete mark is never cleared (D-138). An `insert` that carries
  a null for it is applied without that column, so it cannot clear a set mark either.

A rejected change is not recorded in the feed and not applied, so no other device ever sees it.

**Idempotency is per device.** A change is identified by `(device, deviceSeq)`. One the hub
already holds counts as accepted and is not recorded or applied again, so retrying a batch (after
a timeout, or after a crash between the response and the client's bookkeeping) is harmless.
`deviceSeq` must be unique per device and increasing.

**Recording and applying.** The batch runs in one transaction. Each new change is recorded in the
org's feed and applied to the mirrored tables with the same semantics as the Mac's replay: an
`insert` upserts the columns it carries, an `update` sets one column, a `delete` marks the row
deleted. The hub never removes a synced row (D-089): a deleted row keeps its columns and its column
clocks, every read leaves it out (the snapshot, the relay's routing, the parent check), an update of
it is skipped, and an `insert` of the same id revives it, taking every column it carries whatever
the kept clocks say. The `delete` itself is in the feed like any change, so readers still pull it
and drop the row. A change that cannot apply (an unknown table, a missing parent row, a malformed
shape, a value the column type refuses) is still recorded, so every device's feed stays complete,
but it is skipped and counted in the hub's log; the push still succeeds and `acceptedThrough` still
covers it. Mirrored rows are keyed to the pushing user as well as the org, so another user of the
org pushing the same row id cannot overwrite, update, delete, or adopt as a parent the first user's
row.

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
`threads.readTurnId`, `threads.projectId`, `threads.userDeletedAt`, `projects.name`,
`drafts.threadId`, `drafts.text`, `drafts.updatedAt`. The hub remembers, per row and column, the clock of the change that last set
it (`column_clocks`); an `update` of such a column applies only when its clock is greater, and
an `insert` counts as setting every such column it carries, at its clock. A change that loses is
still recorded in the feed (it is history) but writes nothing. Every other column applies
whatever its clock, as in M8a.

A `macos` device may write any column. An `ios` or `cli` device may only `update` these
columns, and `insert` rows of `drafts`: `threads.title`, `threads.pinned`, `threads.archived`,
`threads.readTurnId`, `threads.userDeletedAt`, `projects.name`, `drafts.threadId`, `drafts.text`,
`drafts.updatedAt`. Anything else (including every `delete`) is rejected with
`column_not_writable`. A draft is cleared by setting `text` to `""`, never by deleting it. A thread is
deleted by setting `userDeletedAt` (never cleared), and its row stays.

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
never moves down, and the mirrored tables are not touched, so pruning never loses a row. A pull
whose `after` is below the horizon (including `after=0` once anything has been pruned, and any
negative `after`) can no longer be served and gets `410 resync_required`. The client then restores
from `GET /v1/snapshot` and continues pulling from the snapshot's `next`. The check and the page
are read in one database snapshot, so a prune that commits during a pull cannot leave the reader
missing rows. Pruning takes the same per-org lock a push holds, for one org's prune at a time, so
it never deletes a row a push is committing.

### `GET /v1/snapshot`

The authenticated user's state, for a reader that got `410 resync_required` (or has nothing yet
and the feed no longer reaches back to `hubSeq` 1). Read in one `REPEATABLE READ` transaction, so
the rows, the clocks, and `next` are one instant while pushes keep landing. Only this user's rows
appear, and no deleted row or its clocks. `200`:

```json
{
  "changes": [ <StoredChange>, ... ],
  "clocks": [ {"table": "threads", "rowId": "thread-1", "column": "title", "hlc": "019a396c76e8-0000-0198..."} ],
  "next": 12
}
```

- `changes` are synthetic `insert`s, one per row, tables in dependency order (`connections`,
  `projects`, `projectFolders`, `threads`, `turns`, `displayItems`, `runtimeRequests`, `drafts`,
  `connectionUsage`),
  rows within a table by id. Each has `hubSeq` 0, `deviceSeq` 0, `wall` 0, `column` `null`,
  `deviceId` the row's owner (the device of its latest insert), and `value` the row's Mac columns
  (no `org_id`, `user_id`, `device_id`, `owner_device_id`, or `deleted_at`;
  `connections.authReference`, `localServerId`, and `target` are `null`, as the hub keeps them).
  `hlc` is the greatest clock of any of the row's clocked columns, or
  `000000000000-0000-<owner device id>` when none was ever set, so any later change of the row
  wins over it.
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
| `table` | string | One of `connections`, `projects`, `projectFolders`, `threads`, `turns`, `displayItems`, `runtimeRequests`, `drafts`, `connectionUsage`. Any other name (including `localServers`, which never syncs) is recorded and skipped. `connectionUsage` (migration 0010) holds a connection's latest plan reading and B4 token totals as JSON documents (`reading`, `tokens`); only a Mac writes it. |
| `rowId` | string | The row's key: its `id`, `threadId` for `drafts`, or `connectionId` for `connectionUsage`. Client-chosen text; unique per org within a table. |
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

A successful upgrade's `101` response carries `Set-Cookie: b4hub-instance=<this instance's id>;
Path=/; Max-Age=3600; Secure; HttpOnly`. An upgrade that reached the wrong instance is
`409 relocated` (next section).

### More than one instance

A hub may run several instances behind one load balancer. Every link of one user (all of that
user's Macs and phones) is served by **one instance at a time**, so commands, replies, watches,
events, holds, and presence never cross instances; no frame is ever forwarded between instances.

- **The claim.** Each instance registers with a UUIDv7 and writes a heartbeat every 5 seconds
  (`B4HUB_HEARTBEAT_MS`); one whose heartbeat is older than four intervals (20 seconds) is dead.
  On an upgrade, after authentication and the revocation check and before the socket exists, the
  instance claims the device's user: if no instance holds the user, or the holder is dead, the
  claim is taken and the link is served here. If another live instance holds the user, the answer
  is

  ```json
  {"error": {"kind": "request_error", "message": "your links are served by another hub instance", "details": {"code": "relocated", "instanceId": "<owner instance id>"}}}
  ```

  with status `409` and no socket, so the device hears no `hello` and the refused link never
  appears in presence or `watching`. A live owner keeps its claim; a draining instance releases
  its claims after its links close, and a dead one's are taken over by the next instance a link
  of that user reaches. An instance whose heartbeat stalled and recovers closes, with code 1001,
  the links of any user another instance took over meanwhile.
- **The cookie.** Every instance sets `Set-Cookie: b4hub-instance=<its own id>` on its `101`
  upgrade responses and on `/readyz`. With the AWS load balancer's application-cookie stickiness
  (cookie name `b4hub-instance`), the load balancer adds its own `AWSALBAPP-*` cookie naming the
  target that sent it, and routes a later request that carries both cookies to that target. The
  `409` deliberately carries no cookie: the load balancer would bind it to the instance that
  refused, which is the wrong one.
- **The client rule.** A device keeps the cookies (name and value) of its last successful upgrade
  response and sends them as `Cookie` on its next upgrade. On `409 relocated` it drops them (they
  point at the wrong target) and retries at once, at most 3 times in a row; after that it uses the
  normal reconnect backoff. A successful link resets the count and keeps the new cookies.
  `instanceId` is informational: a device cannot address an instance directly.

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
another and `watch` it). When the Mac's reply to that `thread.start` is an error without
`details.turnId` (refused before its turn was made, so there is no thread), the hub drops the
auto-watch again. Any other answer (a result, an error with `details.turnId`, or the hub's own
`relay_timeout`) leaves the watch in place until the phone unwatches it or the link closes.

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

**Catch-up (between the Mac and the phone; the hub passes it on like any event).** When a thread
enters a Mac's `watching` set (a new watch, or the Mac's own relink, after which every watched
thread is new to it), the Mac first sends one `message.delta` per message still streaming,
carrying the whole text so far, with `payload.catchUp: true`; live deltas never carry the field.
A phone whose item is still open (the Mac relinked mid-reply) shows only what the catch-up adds to
the text it already has, and nothing when it is the same; one whose shown text does not begin the
catch-up (after a `stream_gap` or its own reconnect) clears the item's live text and shows the whole
catch-up. A phone that ignores the field appends it, as before.

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
| 1001 | the hub is shutting down, or another instance now serves this user's links | reconnect with backoff |
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
over 1 MiB: such a message ends the connection, and the hub drops it without a close frame (no
close code, not 1009), so a device must not send one. Only that device's link ends; the others
are unaffected.

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
drain waits for the links separately). Just before that, every command held for an offline Mac is
answered `device_offline` (a hold never times out silently on an instance nobody is connected to),
and a link writes what is already queued before its close. Once the links are closed, the instance
deletes its claims and its instance row, so its users are claimed at once by the instance they
reconnect to. The whole sequence, the release of the claims included, is bounded by
`B4HUB_SHUTDOWN_WAIT_MS` (default 30000) from the moment the signal arrives: the drain gets the
wait less a reserve for the release (an eighth of it, at most 1 second), anything still open then
is dropped, the release gets what is left, and the process exits. Behind the AWS load balancer with
more than one task, the target group's deregistration delay is 5 seconds, so SIGTERM follows
deregistration almost at once and this drain, not the load balancer, closes the links.

## Maintenance mode

The operator pauses client writes on every hub instance at once with `b4hub maintenance on
[--message "<text>"]` and resumes them with `b4hub maintenance off`; `b4hub maintenance status`
prints the state. "Client writes" means the API's write routes below; the hub's own writes
(`last_seen_at` touches, the daily prune) continue. The message is public: an unauthenticated
`POST /v1/enroll` caller sees it, so it must carry no internal detail. The commands connect with
`DATABASE_ADMIN_URL` (like `seed` and `enroll`) and write one row in `hub_settings`, which the
serving role can only read; no environment variable changes and no instance restarts. Each
`serve` reads the switch before it listens and then every `B4HUB_MAINTENANCE_POLL_MS` (default
5000), so a flip reaches every instance within one interval. A failed read keeps the last value
and logs a warning on every poll until a read succeeds; an instance whose very first read fails
therefore starts with maintenance off (fail-open) until the database answers.

While on, the client writes are refused: `POST /v1/enroll`, `POST /v1/pairing-codes`, `POST
/v1/changes`, `POST /v1/devices/self/push-token`, `DELETE /v1/devices/self`, and the sign-in and account writes `POST /v1/auth/passkey/begin` and
`/finish`, `POST /v1/auth/apple/begin`, `/native`, and `/callback`, `POST /v1/auth/handoff`, `PUT
/v1/me/profile`, `POST /v1/me/passkeys/begin` and `/finish`, `POST /v1/me/apple`, `/native`, and
`/handoff`, `POST /v1/me/step-up/passkey/begin` and `/finish`, `POST /v1/me/step-up/apple`,
`/native`, and `/handoff`, `DELETE /v1/me/identities/{id}`, `DELETE /v1/sessions/self`, and `DELETE /v1/me`. (A
sign-in begin writes a ceremony, so it is refused too; `GET /v1/auth/config` and `GET
/v1/auth/apple/start` are reads.) Each answers `503` with `Retry-After: 30` and

```json
{"error": {"kind": "execution_error", "message": "the hub is in maintenance: <message, or 'writes are paused'>", "details": {"code": "maintenance"}}}
```

before the body is read; on the authenticated routes after the token is checked (a bad token is
still `401`), on `POST /v1/enroll` before the code is checked, and on the sign-in routes after
their rate limit. Reads (`GET /v1/changes`, `GET /v1/snapshot`, `GET /v1/me`,
`GET /v1/devices`), `/healthz`, and `/readyz` are unchanged, except that `/readyz` reports
`"maintenance": "read_only"`. A client treats `maintenance` like a transient failure: keep the
outbox, retry after the header's delay.

Over the link, a client's `turn.send`, `thread.start`, and `request.respond` are answered at once
with a `reply` whose error is `maintenance` and the same message, and are not forwarded.
`turn.lookup`, `turn.interrupt`, and `watch` continue.

## Logging

`b4hub` logs to stderr. `B4HUB_LOG` is the filter (a `tracing` directive such as `info` or
`b4hub=debug,info`; default `info`). `B4HUB_LOG_FORMAT` is `text` or `json`; by default `text`
when stderr is a terminal and `json` otherwise, so a container gets one JSON object per line
without configuration.

Every request runs inside a `request` span with the fields `request_id` (the value of the
response's `X-Request-Id`), `method`, `path` (the matched route pattern, such as `/v1/changes`, or
`(unmatched)`; never the raw path or the query string), `client_request_id` (the caller's
well-formed `X-Request-Id`, when it sent one), and, once the bearer token has been verified,
`device_id` (the device's UUID; the token is never logged). One completion event per
request, `request complete`, carries `status` and `elapsed_ms`: at `WARN` for a `503` (the hub
refusing on purpose: maintenance, shutting down, not ready), `ERROR` for any other 5xx, and `INFO`
otherwise. Headers and bodies are never logged. In JSON the event's own fields are top-level and
the span's fields sit under `span`:

```json
{"timestamp":"2026-11-02T10:15:30.123456Z","level":"INFO","message":"request complete","status":200,"elapsed_ms":12,"target":"b4hub::request_log","span":{"device_id":"0192f0…","method":"POST","path":"/v1/changes","request_id":"0192f0…","name":"request"}}
```
