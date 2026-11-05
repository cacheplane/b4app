# Elixir ecosystem coverage and production operations for b4hub (as of 2026-11-02)

Method note: package figures (latest version, release dates, owners, download counts) were pulled live from the hex.pm JSON API (`https://hex.pm/api/packages/<name>` and `/owners`) on 2026-11-02; GitHub figures (stars, last push, open issues, archived flag) from `https://api.github.com/repos/<owner>/<repo>` the same day. Hex "recent" downloads = the trailing 90 days. Hexdocs now redirects `hexdocs.pm/<pkg>` to `<pkg>.hexdocs.pm`; URLs below use the new form.

Snapshot table (all from hex.pm API / GitHub API, 2026-11-02):

| Package | Latest | Released | All-time DL | 90-day DL | Hex owner(s) | GitHub |
|---|---|---|---|---|---|---|
| wax_ (WebAuthn) | 0.7.0 | 2025-05-18 | 555,688 | 270,738 | tangui (1 person) | tanguilp/wax: 234 stars, last push 2026-10-12, 8 open issues |
| webauthn_components | 0.11.3 | 2026-10-17 | 8,357 | 1,042 | type1fool | liveshowy/webauthn_components: 216 stars, push 2026-11-01 |
| webauthn (scalpel) | 0.0.9 | 2024-06-19 | 4,910 | 301 | - | effectively dormant |
| assent | 0.3.2 | 2026-10-28 | 2,448,831 | 472,026 | danschultzer (pow-auth) | 536 stars, push 2026-11-02, 4 open issues |
| ueberauth_apple | 0.7.0 | 2026-07-14 | 282,385 | 65,327 | ueberauth org | standalone repo archived; moved into ueberauth monorepo |
| ueberauth | 0.11.0 | 2026-10-11 | 10,450,448 | 675,347 | - | - |
| jose (erlang-jose) | 1.11.13 | 2026-10-26 | 114,744,046 | 3,865,725 | - | potatosalad/erlang-jose |
| joken | 2.7.0 | 2026-08-28 | 59,156,657 | 2,339,733 | - | joken-elixir/joken |
| joken_jwks | 1.8.0 | 2026-08-28 | 4,448,617 | 322,399 | - | - |
| pigeon (APNs/FCM) | 2.1.0 | 2026-09-08 | 27,240,364 | 152,407 | hpopp (codedge-llc) | 684 stars, push 2026-09-08, 30 open issues |
| kadabra (HTTP/2) | 0.6.3 | 2026-07-01 | 26,986,601 | 113,802 | - | codedge-llc/kadabra |
| apns (apns4ex) | 0.9.4 | 2016-08-22 | 114,396 | 468 | - | abandoned |
| sparrow (APNs/FCM) | 1.1.5 | 2021-03-04 | 43,257 | 188 | - | abandoned |
| finch | 0.24.0 | 2026-09-29 | 64,134,655 | 5,424,263 | - | sneako/finch: 1,366 stars, push 2026-10-29 |
| mint | 1.11.0 | 2026-09-28 | 69,516,871 | 6,598,876 | - | elixir-mint/mint |
| req | 0.7.5 (0.8.0-rc.0 2026-08-18) | 2026-10-06 | 19,306,309 | 4,385,606 | wojtekmach | - |
| ecto | 3.14.2 | 2026-08-14 | 150,679,371 | 6,091,065 | - | elixir-ecto/ecto |
| ecto_sql | 3.14.0 | 2026-05-19 | 131,773,595 | 5,473,460 | - | elixir-ecto/ecto_sql |
| postgrex | 0.22.4 | 2026-08-07 | 143,246,383 | 5,247,428 | - | elixir-ecto/postgrex |
| hammer | 7.5.1 | 2026-10-27 | 32,512,981 | 1,006,657 | epinault | ExHammer/hammer: 923 stars, push 2026-11-02, 1 open issue |
| hammer_backend_redis | 7.2.0 | 2026-09-08 | 23,374,413 | 246,394 | - | - |
| plug_attack | 0.4.3 | 2021-08-09 | 1,744,114 | 80,565 | michalmuskala | 455 stars, last push 2025-04-18 |
| ex_rated | 2.1.0 | 2021-12-08 | 6,608,186 | 326,696 | grempe | 461 stars, last push 2023-03-30 |
| bandit (HTTP server) | 1.14.1 | 2026-10-28 | 17,372,755 | 4,420,963 | - | mtrudel/bandit |
| phoenix | 1.8.16 | 2026-10-20 | 159,269,372 | 6,230,076 | - | - |
| phoenix_live_dashboard | 0.9.1 | 2026-08-31 | 37,736,722 | 3,171,032 | - | - |
| opentelemetry (SDK) | 1.7.0 | 2025-10-17 | 31,960,532 | 2,653,417 | - | open-telemetry/opentelemetry-erlang |
| opentelemetry_api | 1.5.0 | 2025-10-17 | 33,848,919 | 2,847,271 | - | - |
| opentelemetry_exporter | 1.11.0 | 2026-09-16 | 30,237,996 | 2,276,626 | - | - |
| opentelemetry_ecto | 1.2.0 | 2024-02-06 | 10,447,576 | 1,355,932 | - | contrib repo: 59 open issues |
| opentelemetry_phoenix | 2.0.1 | 2025-02-21 | 11,517,587 | 1,507,773 | - | contrib repo |
| opentelemetry_bandit | 0.3.0 | 2025-08-21 | 2,255,538 | 770,570 | - | contrib repo |
| prom_ex | 1.12.0 | 2026-06-19 | 5,786,314 | 690,544 | akoutmos | - |
| rustler | 0.38.0 | 2026-05-25 | 6,676,386 | 1,071,965 | - | rusterlium/rustler: 4,891 stars, push 2026-10-23, 56 open issues |
| rustler_precompiled | 0.10.1 | 2026-10-24 | 9,570,140 | 2,777,190 | - | philss/rustler_precompiled |
| x509 | 0.9.2 | 2025-07-18 | 5,165,547 | 638,142 | - | voltone/x509 |

Sources for the table: hex.pm package API pages, e.g. [hex.pm/api/packages/wax_](https://hex.pm/api/packages/wax_), [pigeon](https://hex.pm/api/packages/pigeon), [hammer](https://hex.pm/api/packages/hammer), [assent](https://hex.pm/api/packages/assent), [postgrex](https://hex.pm/api/packages/postgrex), [rustler](https://hex.pm/api/packages/rustler) (and the equivalent `/api/packages/<name>` URL for every row); GitHub repo API, e.g. [api.github.com/repos/tanguilp/wax](https://api.github.com/repos/tanguilp/wax), [codedge-llc/pigeon](https://api.github.com/repos/codedge-llc/pigeon), [ExHammer/hammer](https://api.github.com/repos/ExHammer/hammer), [rusterlium/rustler](https://api.github.com/repos/rusterlium/rustler).

## WebAuthn / passkeys in Elixir (Wax, webauthn_components, others)

### Takeaway
There is exactly one serious server-side WebAuthn verifier in Elixir: `wax_` (Wax), a single-maintainer library at 0.7.0 (last release 2025-05-18) that passes the FIDO conformance suite, supports discoverable/usernameless flows, and handles packed/TPM/U2F/Apple/Android-key attestation plus FIDO MDS3, but has never had an independent security review. `webauthn_components` is a LiveView UI wrapper (useless for b4hub's native ASAuthorization clients), and other packages are dormant.

### Cited Findings
- Wax is published on Hex as `wax_` (the `wax` name belongs to an unrelated WhatsApp package); latest 0.7.0 released 2025-05-18; prior releases 0.6.7 (2025-02-17), 0.6.6 (2024-10-24), 0.6.5 (2024-03-31); sole Hex owner `tangui`; 555,688 all-time and 270,738 trailing-90-day downloads — [hex.pm API wax_](https://hex.pm/api/packages/wax_); [hex.pm API wax (unrelated)](https://hex.pm/api/packages/wax)
- GitHub tanguilp/wax: 234 stars, last push 2026-10-12, 8 open issues, not archived (i.e., commits after the last Hex release) — [GitHub API](https://api.github.com/repos/tanguilp/wax)
- Wax's stated goal is "a comprehensive FIDO2 library"; README says it "Passes all the 170 tests" of the official FIDO test suite — [tanguilp/wax README](https://github.com/tanguilp/wax)
- Attestation formats: mandatory packed, TPM, U2F (fido-u2f), Apple Anonymous; optional Android key; Android SafetyNet removed in v0.7.0. Attestation types basic, self, private CA (AttCA); ECDAA optional — [tanguilp/wax README](https://github.com/tanguilp/wax)
- FIDO Metadata Service v3: loaded automatically over HTTP when `:update_metadata` is true, or from a local `:metadata_dir`; TOC verified against x5c and CRLs — [tanguilp/wax README](https://github.com/tanguilp/wax)
- Explicit warning in README: "This library has not be reviewed by independent security / FIDO2 specialists - use it at your own risks"; requires OTP 25+; ships no JavaScript client — [tanguilp/wax README](https://github.com/tanguilp/wax)
- Discoverable credentials / passkeys: the `authenticate/6` docs have a "Self-discoverable credentials (resident keys)" section — you may call the WebAuthn API without `:allow_credentials`; the browser returns a `userHandle` that the server uses to look up keys before calling `authenticate/6`. Options: `user_verification` ("discouraged" | "preferred" | "required", default "preferred"), `attestation` ("none" | "direct", default "none"), `origin` (string or list), `rp_id` (string or `:auto`), `trusted_attestation_types` (default `[:none, :basic, :uncertain, :attca, :anonca, :self]`), `verify_trust_root` (default true; applies only to u2f and packed). No explicit resident-key option on registration challenges is documented — [Wax v0.7.0 docs](https://wax-.hexdocs.pm/Wax.html)
- `webauthn_components` 0.11.3 (2026-10-17; burst of 0.10.0 → 0.11.3 between 2026-09-12 and 2026-10-17, previous release 0.8.0 on 2024-08-29); 8,357 all-time downloads; sole owner `type1fool` — [hex.pm API](https://hex.pm/api/packages/webauthn_components)
- `webauthn_components` describes itself as "Passkey authentication for Phoenix LiveView applications"; provides LiveView components + JS hooks (`RegistrationHook`, `AuthenticationHook`); persistence is the host's job; the `wac.install` generator was removed in v0.10 — [webauthn_components README](https://github.com/liveshowy/webauthn_components)
- `webauthn` (scalpel-software) 0.0.9, last release 2024-06-19, 4,910 total downloads — [hex.pm API](https://hex.pm/api/packages/webauthn)

### Inferences
- For b4hub (native iOS/macOS clients calling a JSON API; no browser LiveView), only `wax_` is relevant. Its feature coverage is adequate for the hub's needs (passkeys with attestation "none", usernameless sign-in via userHandle), comparable in scope to Rust's `webauthn-rs`, but with a bus factor of one and roughly 18 months since its last Hex release despite ongoing commits.
- Apple passkeys typically use attestation "none" (Wax's default) — so MDS/attestation-chain features are not on the critical path.
- The adoption gap is notable: wax_ has ~556k downloads vs. assent's 2.4M or joken's 59M; WebAuthn is a niche in Elixir.

### Gaps
- Did not verify whether the post-0.7.0 commits on GitHub (to 2026-10-12) add WebAuthn Level 3 features (e.g., JSON serialization helpers, `hints`) or whether a 0.8 release is planned.
- No independent security audit of Wax was found (README states none exists).

## Sign in with Apple (ueberauth_apple, Assent, JOSE/Joken)

### Takeaway
For the web redirect flow, Assent (actively maintained, 0.3.2 on 2026-10-28) and ueberauth_apple (0.7.0, 2026-07-14, now living in the ueberauth monorepo) both work. For b4hub's native flow (verify an Apple identity token posted by the app), the idiomatic path is JOSE or Joken + `joken_jwks` against `https://appleid.apple.com/auth/keys`, and AES-GCM sealing is available directly from OTP's `:crypto` — all very mature, heavily downloaded libraries.

### Cited Findings
- Assent 0.3.2 released 2026-10-28 (prior 0.3.1 on 2025-06-20, 0.3.0 on 2025-01-06); 2.45M all-time, 472k 90-day downloads; maintained by Dan Schultzer (pow-auth), 536 stars, last push 2026-11-02, 4 open issues — [hex.pm API](https://hex.pm/api/packages/assent); [GitHub API](https://api.github.com/repos/pow-auth/assent)
- `Assent.Strategy.Apple` is an OpenID Connect strategy needing Team ID, Services ID, Key ID and the .p8 key (path or content); its OpenID configuration hard-codes `jwks_uri` = `https://appleid.apple.com/auth/keys`, token endpoint `/auth/token`; surfaces Apple claims `is_private_email`, `real_user_status`, `org_id`; name is only available via an unverified `user` param (`include_unverified_name: true`) — [assent apple.ex source](https://github.com/pow-auth/assent/blob/main/lib/assent/strategies/apple.ex)
- ueberauth_apple 0.7.0 and 0.6.2 both released 2026-07-14 (previous 0.6.1 on 2023-06-21); 282k all-time downloads. The standalone repo is archived: "This repository has moved... now developed in the Überauth repository at strategies/ueberauth_apple"; still published to Hex under the same name — [hex.pm API](https://hex.pm/api/packages/ueberauth_apple); [ueberauth_apple README](https://github.com/ueberauth/ueberauth_apple)
- ueberauth core 0.11.0 released 2026-10-11 (previous 0.10.8 on 2024-02-27) — [hex.pm API](https://hex.pm/api/packages/ueberauth)
- erlang-jose 1.11.13 released 2026-10-26; 114.7M all-time downloads — [hex.pm API](https://hex.pm/api/packages/jose)
- Joken 2.7.0 released 2026-08-28 (previous 2.6.2 on 2024-08-10); 59.2M downloads; `joken_jwks` 1.8.0 released 2026-08-28, 4.4M downloads (JWKS fetching/caching for Joken) — [hex.pm API joken](https://hex.pm/api/packages/joken); [hex.pm API joken_jwks](https://hex.pm/api/packages/joken_jwks)
- OTP's `:crypto` module supports `aes_256_gcm` AEAD (via `crypto_one_time_aead`) — [Erlang crypto docs](https://www.erlang.org/doc/apps/crypto/crypto.html)

### Inferences
- The Rust hub's `apple.rs` (Apple client + identity-token verification + AES-GCM seals) maps to roughly: `joken` + `joken_jwks` (or `jose` directly) for RS256 token verification with `iss`/`aud`/`exp`/nonce checks, `:crypto.crypto_one_time_aead(:aes_256_gcm, ...)` for seals, and `jose`'s ES256 signing for the Apple client-secret JWT used in the token/revoke endpoints. Assent's Apple strategy is built around the browser authorization-code flow; it is usable for code exchange, but native identity-token verification would likely be ~50–100 lines of custom code either way.
- Maintenance risk is low here: JOSE/Joken are among the most-downloaded security packages on Hex.

### Gaps
- Did not verify whether Assent exposes a public helper to verify a bare Apple `id_token` (without going through `callback/2`).
- Did not confirm whether ueberauth_apple 0.7.0 supports Apple's token revocation endpoint (required for account deletion on iOS).

## APNs (Pigeon, apns4ex, Finch/Mint-based custom)

### Takeaway
Pigeon 2.1.0 (2026-09-08) is the only maintained APNs library; it supports token (.p8, ES256 JWT) auth, `push_type`, `collapse_id`, `priority`, `expiration`, `content-available`, and now runs on Mint with auto-reconnect. apns4ex and Sparrow are abandoned. A hand-rolled Finch/Mint HTTP/2 client plus JOSE ES256 is a realistic alternative (~same size as the Rust `ApnsSender`).

### Cited Findings
- Pigeon 2.1.0 released 2026-09-08; previous 2.0.1 (2024-12-28), 2.0.0 (2024-12-09) after a long rc period (2.0.0-rc.2 2024-01-17); 27.2M all-time but only 152k 90-day downloads; sole Hex owner `hpopp` (codedge-llc); 684 stars, 30 open issues — [hex.pm API](https://hex.pm/api/packages/pigeon); [GitHub API](https://api.github.com/repos/codedge-llc/pigeon)
- Pigeon 2.1.0 changelog: "Use Mint for all HTTP/1 and HTTP/2 connections. This replaces the use of :httpoison and :kadabra"; dispatchers reconnect on their own and connect in the background (no longer crash the app if APNs is unreachable); new `:not_connected` response (push never sent, safe to resend) vs `:timeout` (sent, delivery unknown); adds Apple's newer token errors `:bad_environment_key_id_in_token` and `:unrelated_key_id_in_token`; redacts PKCS#8 keys in config errors; minimum Elixir 1.16 — [Pigeon CHANGELOG](https://github.com/codedge-llc/pigeon/blob/main/CHANGELOG.md)
- Token auth config: `adapter: Pigeon.APNS, key: File.read!("AuthKey.p8"), key_identifier: "ABC1234567", team_id: ..., mode: :dev | :prod`; dispatchers are supervised processes (`use Pigeon.Dispatcher`); pushes are synchronous and return the notification with `:response` set — [Pigeon.APNS source/moduledoc](https://github.com/codedge-llc/pigeon/blob/main/lib/pigeon/apns.ex)
- `Pigeon.APNS.Notification` fields: `device_token`, `topic`, `push_type` (string, e.g. "alert"), `collapse_id`, `expiration`, `priority`, `id`, `payload` (string-keyed map), `response`; helpers `put_content_available/1`, `put_mutable_content/1`, `put_custom/2`, plus `alert`, `badge`, `category`, `sound`, `interruption-level`, `target-content-id`, `thread-id`. Errors are the snake_case of the APNs `reason` (e.g. `:expired_provider_token`), unknowns map to `:unknown_error` — [Pigeon.APNS.Notification docs](https://pigeon.hexdocs.pm/Pigeon.APNS.Notification.html)
- `apns` (chvanikoff/apns4ex) last release 0.9.4 on 2016-08-22; `sparrow` last release 1.1.5 on 2021-03-04 — [hex.pm API apns](https://hex.pm/api/packages/apns); [hex.pm API sparrow](https://hex.pm/api/packages/sparrow)
- Finch 0.24.0 (2026-09-29) and Mint 1.11.0 (2026-09-28) are actively released with ~5.4M and ~6.6M 90-day downloads; kadabra 0.6.3 (2026-07-01) is now dropped by Pigeon — [hex.pm API finch](https://hex.pm/api/packages/finch); [hex.pm API mint](https://hex.pm/api/packages/mint); [hex.pm API kadabra](https://hex.pm/api/packages/kadabra)

### Inferences
- `push_type` is a free-form string, so `"background"` (with `priority: 5` and `content-available`) is expressible even though the docs only show `"alert"`. b4hub's "withdraw" pattern (a background push naming notification keys) is application payload, so Pigeon does not need explicit support; `collapse_id` (b4hub's `request:<id>`/`turn:<id>` keys) is a first-class field.
- Pigeon's 90-day downloads (152k) are small relative to its all-time count, suggesting many apps moved to FCM-only or custom code; the v2.1 rewrite on Mint (Sept 2026) is recent and less battle-tested than the old kadabra path.
- For a spool-sender equivalent (Simulator), a behaviour/module swap in Elixir is trivial; Pigeon also ships a sandbox-style `mode: :dev`.

### Gaps
- Did not verify Pigeon's ES256 provider-token caching/refresh interval (Apple requires refresh no more than every 20 minutes and no less than hourly).
- No production post-mortems of Pigeon 2.1's Mint transport found yet (release is ~2 months old).

## PostgreSQL: Ecto/Postgrex, raw SQL migrations, LISTEN/NOTIFY, transactions

### Takeaway
Ecto (3.14.2, 2026-08-14), ecto_sql (3.14.0, 2026-05-19) and Postgrex (0.22.4, 2026-08-07) are core-team-maintained and among the most-downloaded packages on Hex. A hand-written SQL schema maps fine: Ecto migrations accept raw `execute/1` SQL, schemas are optional, and `Repo.query/3` runs arbitrary SQL. `Postgrex.Notifications` provides LISTEN/NOTIFY but explicitly drops notifications during disconnects.

### Cited Findings
- ecto 3.14.2 (2026-08-14; 3.14.0 on 2026-05-19), 150.7M downloads; ecto_sql 3.14.0 (2026-05-19), 131.8M; postgrex 0.22.4 (2026-08-07; 0.22.0 on 2026-01-10), 143.2M — [hex.pm API ecto](https://hex.pm/api/packages/ecto); [ecto_sql](https://hex.pm/api/packages/ecto_sql); [postgrex](https://hex.pm/api/packages/postgrex)
- `Postgrex.Notifications` (v0.22.4): a separate supervised process holding its own connection; `listen/3` returns `{:ok, ref}` or `{:eventually, ref}`; messages arrive as `{:notification, pid, ref, channel, payload}`; `:auto_reconnect` defaults to false (process terminates on disconnect); with it, listens are queued until reconnected, but "any notifications that occur during the disconnection period are not queued and cannot be recovered"; docs recommend the subscribe → fetch current data → handle notifications pattern; channel names are quoted (case-sensitive) — [Postgrex.Notifications docs](https://postgrex.hexdocs.pm/Postgrex.Notifications.html)
- Ecto SQL Sandbox (v3.14.0): each test checks out a connection wrapped in a transaction that is rolled back; only PostgreSQL supports concurrent (async) sandbox tests; manual vs shared modes; `allow/4` and caller tracking let spawned processes share the test connection; `start_owner!/2` for unlinked processes; default 120 s ownership timeout; deferred constraints are never checked (use `SET CONSTRAINTS ALL IMMEDIATE`) — [Ecto.Adapters.SQL.Sandbox docs](https://ecto-sql.hexdocs.pm/Ecto.Adapters.SQL.Sandbox.html)
- `mix release` docs recommend running migrations with `bin/app eval`, which "starts its own instance of the VM but without starting any of the applications" (you must start Repo explicitly) — [Mix.Tasks.Release docs (Elixir 1.20.5)](https://mix.hexdocs.pm/Mix.Tasks.Release.html)

### Inferences
- b4hub's existing hand-written SQL migrations can be carried over nearly verbatim inside Ecto migration modules via `execute("...")`, or kept as `.sql` files run by a small migrator; Ecto schemas can then be declared over existing tables (`@primary_key`, custom types) or skipped entirely in favour of `Repo.query!/3` for the change-log push/pull (closest to sqlx's raw-query style, but without sqlx's compile-time checked queries — Elixir has no equivalent of `sqlx::query!`).
- `Repo.transaction/2` (or `Ecto.Multi`) covers the hub's "detect notifications inside `changes::push`" transaction pattern.
- Because the sandbox wraps every test in a transaction, any code that relies on NOTIFY delivery (only sent at COMMIT) or on its own nested transaction semantics will behave differently under test — those tests need `async: false` / non-sandboxed connections. This is a known tension, though not documented on the sandbox page.
- The sandbox replaces b4hub's current `test-db.sh` throwaway-Postgres pattern for most tests; a real Postgres server is still needed (no in-memory option).

### Gaps
- Sandbox page does not discuss LISTEN/NOTIFY or app-level transactions; the "NOTIFY never fires inside a rolled-back sandbox transaction" point is inferred from PostgreSQL semantics, not a cited Ecto doc.
- No Elixir equivalent of sqlx compile-time query checking was researched in depth.

## Rate limiting (Hammer, PlugAttack, ExRated)

### Takeaway
Hammer 7.x is the clear choice: actively released (7.5.1 on 2026-10-27), ETS/atomic/Redis/Mnesia backends, fixed-window, sliding-window, leaky- and token-bucket algorithms. PlugAttack and ExRated are effectively frozen (last releases 2021).

### Cited Findings
- Hammer 7.5.1 released 2026-10-27; 7.5.0 (2026-09-02), 7.4.1 (2026-08-29), 7.4.0 (2026-05-19), 7.3.0 (2026-03-31), 7.2.0 (2026-02-05); 32.5M all-time, ~1.0M 90-day downloads; Hex owner `epinault`; 923 stars, 1 open issue — [hex.pm API](https://hex.pm/api/packages/hammer); [GitHub API](https://api.github.com/repos/ExHammer/hammer)
- Hammer has no global configuration; each limit is checked with `MyApp.RateLimit.hit(key, scale, limit)`; backends `Hammer.ETS` (default, can be distributed), `Hammer.Atomic` (fastest, single node), `Hammer.Redis`, `Hammer.Mnesia`; algorithms include FixWindow, FixWindowPerKey, LeakyBucket, TokenBucket, SlidingWindow (ETS); tutorial covers using it as a Plug — [Hammer README](https://github.com/ExHammer/hammer)
- hammer_backend_redis 7.2.0 released 2026-09-08 — [hex.pm API](https://hex.pm/api/packages/hammer_backend_redis)
- PlugAttack 0.4.3, last release 2021-08-09 (owner michalmuskala), last repo push 2025-04-18 — [hex.pm API](https://hex.pm/api/packages/plug_attack); [GitHub API](https://api.github.com/repos/michalmuskala/plug_attack)
- ExRated 2.1.0, last release 2021-12-08, last repo push 2023-03-30 — [hex.pm API](https://hex.pm/api/packages/ex_rated); [GitHub API](https://api.github.com/repos/grempe/ex_rated)

### Inferences
- b4hub's per-IP auth limits (`auth_limits.rs`) map to a few lines of Hammer `hit/3` in a Plug, keyed on the client IP. On ECS behind an ALB, the IP must come from `X-Forwarded-For` (e.g. the `remote_ip` package or a custom plug) — the same trust problem the Rust service already handles.
- In-memory ETS state is per-node, like the Rust hub's in-memory limits; multi-task scaling would need the Redis backend.

### Gaps
- Did not check `remote_ip` package maintenance status.

## HTTP/2 clients (Finch / Mint)

### Takeaway
Mint (low-level, process-less HTTP/1+2) and Finch (pooled client on Mint, HTTP/2 supported) are the de facto HTTP stack, both released in late September 2026, and Req layers a high-level API on Finch. Pigeon now uses Mint directly.

### Cited Findings
- Mint 1.11.0 (2026-09-28; 1.10.2 2026-09-29, 1.10.1 2026-09-19); 69.5M all-time, 6.6M 90-day downloads — [hex.pm API](https://hex.pm/api/packages/mint)
- Finch 0.24.0 (2026-09-29; 0.23.0 2026-06-17, 0.22.0 2026-05-12); 64.1M all-time; 1,366 stars, 26 open issues, last push 2026-10-29 — [hex.pm API](https://hex.pm/api/packages/finch); [GitHub API](https://api.github.com/repos/sneako/finch)
- Req 0.7.5 (2026-10-06), 0.8.0-rc.0 (2026-08-18); 4.4M 90-day downloads — [hex.pm API](https://hex.pm/api/packages/req)
- Pigeon 2.1.0 replaced kadabra/httpoison with Mint for all HTTP/2 — [Pigeon CHANGELOG](https://github.com/codedge-llc/pigeon/blob/main/CHANGELOG.md)
- Bandit (the HTTP server) 1.14.1 released 2026-10-28; 4.4M 90-day downloads — [hex.pm API](https://hex.pm/api/packages/bandit)

### Inferences
- A custom APNs sender = a Finch pool with `protocols: [:http2]` to `api.push.apple.com` + a cached ES256 JWT from `jose`; this mirrors the Rust `ApnsSender` design one-to-one.

### Gaps
- Did not verify Finch's HTTP/2 pool limits (Finch HTTP/2 pools historically use a single connection per pool) against APNs' per-connection stream limits.

## Deployment and operations (mix release, Docker, ECS Fargate, footprint, observability, hot upgrades)

### Takeaway
`mix release` produces a self-contained tarball (bundles ERTS) that drops into a standard multi-stage Docker image and runs on ECS Fargate like any other container; runtime config comes from `config/runtime.exs` (env vars/Secrets Manager injection), migrations via `bin/app eval`. Hot code upgrades are not supported out of the box and the official docs discourage them. Observability is strong via Telemetry, LiveDashboard and OpenTelemetry, though some OTel contrib instrumentations lag.

### Cited Findings
- `mix release` (Elixir 1.20.5 docs): releases include the Erlang VM and runtime by default (`include_erts: true`, "the recommended value"), and run on targets with "the same operating system (OS) distribution and version" as the build machine; `include_erts: false` requires the exact ERTS version on the target — [Mix.Tasks.Release](https://mix.hexdocs.pm/Mix.Tasks.Release.html)
- Hot upgrades: "this feature is not supported out of the box by Elixir releases"; they are "very complicated to perform in practice" (requires `.appup` recipes per changed application and a `.relup`), and "hot upgrades are rarely a viable option" given other deployment techniques — [Mix.Tasks.Release](https://mix.hexdocs.pm/Mix.Tasks.Release.html)
- `config/runtime.exs` executes whenever the release starts; must `import Config`; cannot use Mix — [Mix.Tasks.Release](https://mix.hexdocs.pm/Mix.Tasks.Release.html)
- Memory: Elixir Forum reports ~70 MB for a small `mix run` SQS consumer, and that releases use more memory than `mix run` because releases preload all modules (embedded mode); one ECS Fargate user reported occasional exit code 137 (OOM) kills without a confirmed fix — [Elixir Forum: Elixir memory usage](https://elixirforum.com/t/elixir-memory-usage/21444); search summary of forum threads (no authoritative Fargate benchmark found)
- A 2026 containerization guide recommends releases in containers and cautions BEAM scheduler/GC defaults are usually correct; set `+S` only after measuring — [OneUptime blog, 2026-02-08](https://oneuptime.com/blog/post/2026-02-08-how-to-containerize-an-elixir-phoenix-application-with-docker/view)
- Phoenix LiveDashboard 0.9.1 (2026-08-31; 0.9.0 2026-08-12, previous 0.8.7 2025-04-28) — [hex.pm API](https://hex.pm/api/packages/phoenix_live_dashboard)
- OpenTelemetry Erlang/Elixir: SDK `opentelemetry` 1.7.0 and `opentelemetry_api` 1.5.0 (both 2025-10-17), `opentelemetry_exporter` 1.11.0 (2026-09-16); contrib instrumentations `opentelemetry_phoenix` 2.0.1 (2025-02-21), `opentelemetry_bandit` 0.3.0 (2025-08-21), `opentelemetry_ecto` 1.2.0 (2024-02-06, ~33 months old); contrib repo has 59 open issues — [hex.pm API opentelemetry](https://hex.pm/api/packages/opentelemetry); [opentelemetry_exporter](https://hex.pm/api/packages/opentelemetry_exporter); [opentelemetry_ecto](https://hex.pm/api/packages/opentelemetry_ecto); [opentelemetry_phoenix](https://hex.pm/api/packages/opentelemetry_phoenix); [opentelemetry_bandit](https://hex.pm/api/packages/opentelemetry_bandit); [GitHub API contrib](https://api.github.com/repos/open-telemetry/opentelemetry-erlang-contrib)
- Prometheus: `prom_ex` 1.12.0 (2026-06-19); `telemetry_metrics_prometheus` 1.1.0 (2021-07-20, stale) — [hex.pm API prom_ex](https://hex.pm/api/packages/prom_ex); [hex.pm API telemetry_metrics_prometheus](https://hex.pm/api/packages/telemetry_metrics_prometheus)
- OTP release cadence: OTP 29.1.2, 28.5.0.8, 27.3.4.19 all published 2026-10-14 (three supported majors patched in parallel) — [GitHub API erlang/otp releases](https://api.github.com/repos/erlang/otp/releases)
- Elixir patch releases 1.20.5, 1.19.7 and 1.18.6 published 2026-10-29 (three branches maintained) — [GitHub API elixir-lang/elixir releases](https://api.github.com/repos/elixir-lang/elixir/releases)

### Inferences
- Operationally, an Elixir b4hub keeps the same shape as today: one Docker image, one ECS service, Terraform unchanged apart from env/secrets and health checks. The `B4HUB_APNS_PRIVATE_KEY_FILE`-style secret injection maps to `System.fetch_env!/1` or `File.read!/1` in `runtime.exs`.
- Memory: expect a higher idle baseline than the Rust binary (tens of MB vs single-digit MB); a 512 MB Fargate task is comfortable for a small hub, but this is an inference from forum anecdotes, not a benchmark. Boot time for a release is typically on the order of a second or two, which matters little for an always-on ECS service (cold start is mainly a Lambda concern).
- ECS rolling deploys (new task → health check → drain old) make hot code upgrades unnecessary; they also conflict with immutable-container practice.
- The BEAM sizes schedulers from visible CPUs; on fractional-vCPU Fargate tasks, scheduler count and busy-wait settings (`+sbwt none`) are worth tuning to avoid inflated CPU metrics — this is common practice but not verified in this research.
- OpenTelemetry tracing works but the Ecto instrumentation has not had a release since early 2024; Telemetry events themselves are first-class in Phoenix/Ecto/Bandit.

### Gaps
- No authoritative, current benchmark of idle RSS or boot time for a Phoenix/Bandit release on Fargate was found; forum anecdotes only.
- Did not verify current Fly.io or AWS official Elixir deployment guides.
- Did not confirm the claim that Phoenix generators default to Bandit (believed true since Phoenix 1.7.11, early 2024) in this session.

## Developer-experience costs (learning curve, typing in 1.19/1.20, Expert/ElixirLS, testing)

### Takeaway
Elixir 1.20 (2026-06-03) made the language gradually typed with inference over all constructs — catching "verified bugs" without annotations — but user-written type signatures are still not available, so it remains far looser than Swift or Rust. Tooling improved: Expert, the official language server, reached tagged releases (v0.2.2, 2026-10-23) and ElixirLS is still maintained. Testing against a real Postgres is idiomatic and pleasant via the SQL sandbox.

### Cited Findings
- Elixir blog timeline: v1.19 released 2025-10-16 ("enhanced type checking and up to 4x faster compilation for large projects"; adds type checking of protocols and anonymous functions); 2026-01-09 "Type inference of all constructs and the next 15 months" (v1.20 RC); v1.20 released 2026-06-03 "now a gradually typed language" — [elixir-lang.org blog index](https://elixir-lang.org/blog/)
- v1.20 performs "type inference and gradually type check every Elixir program, without introducing type annotations"; focuses on "verified bugs" (typing violations guaranteed to fail at runtime), dead code and redundant clauses, with a claimed very low false-positive rate; typed struct definitions and then type signatures come later, gated on performance work, recursive types, parametric types; no dates given — [Elixir v1.20 release post](https://elixir-lang.org/blog/2026/06/03/elixir-v1-20-0-released/)
- Latest patch releases: Elixir 1.20.5 (2026-10-29) — [GitHub API](https://api.github.com/repos/elixir-lang/elixir/releases)
- Expert ("the official language server implementation for the Elixir programming language") repo is `expert-lsp/expert`: 2,070 stars, last push 2026-11-03; tagged releases v0.1.10 (2026-09-08), v0.1.11 (2026-10-01), v0.2.0 (2026-10-21), v0.2.1 and v0.2.2 (2026-10-23), plus nightly builds — [GitHub API expert-lsp/expert releases](https://api.github.com/repos/expert-lsp/expert/releases); [Expert README](https://github.com/expert-lsp/expert)
- Earlier sources described Expert as "currently in alpha" and a January 2026 forum post said only nightly builds existed; the Expert project was announced Aug 2024 when the official language server team formed — [elixir-lang.org blog 2024-08-15](https://elixir-lang.org/blog/2024/08/15/welcome-elixir-language-server-team/); [ElixirForum Zed thread](https://elixirforum.com/t/how-are-you-configuring-zed-for-elixir-lsp-formatter-tips/73947)
- ElixirLS (elixir-lsp/elixir-ls) still active: 1,780 stars, last push 2026-10-27, 53 open issues — [GitHub API](https://api.github.com/repos/elixir-lsp/elixir-ls)
- Ecto SQL Sandbox supports async tests against PostgreSQL with per-test rolled-back transactions — [Ecto.Adapters.SQL.Sandbox](https://ecto-sql.hexdocs.pm/Ecto.Adapters.SQL.Sandbox.html)

### Inferences
- For a developer fluent in Swift and Rust, the biggest adjustments are dynamic typing at API boundaries (JSON decoding without serde/Codable-style compile-time guarantees; Ecto changesets or `Ecto.Schema` embedded schemas play that role), OTP supervision concepts, and losing sqlx's compile-time-checked SQL. The 1.20 inference catches some errors but is not a substitute for Rust's type system.
- Expert at 0.2.x is usable but young (sub-1.0, frequent releases); ElixirLS remains the conservative fallback.
- Hiring is not a constraint for a solo owner, but the contributor pool is smaller than Rust's; this was not quantified.

### Gaps
- No quantitative hiring/learning-curve data was gathered (e.g., Stack Overflow survey share for Elixir in 2025/2026).
- Did not verify whether Expert v0.2 is now the default recommendation in VS Code's official Elixir extension.

## Interop with Rust (Rustler NIFs, scheduler blocking, ports, sidecar)

### Takeaway
Rustler (0.38.0, 2026-05-25) plus `rustler_precompiled` (0.10.1, 2026-10-24) is a mature, actively maintained way to call Rust from Elixir, but a NIF runs inside the VM: it must return within ~1 ms or be marked dirty, and a crash takes down the whole node. For b4hub, reusing Rust code is better done for pure, short functions (or not at all), with ports or a sidecar container for anything long-running.

### Cited Findings
- rustler 0.38.0 released 2026-05-25 (0.37.3 2026-02-11; 0.37.0 retired for a workspace bug); 6.7M all-time, ~1.07M 90-day downloads; rusterlium/rustler 4,891 stars, 56 open issues, last push 2026-10-23 — [hex.pm API](https://hex.pm/api/packages/rustler); [GitHub API](https://api.github.com/repos/rusterlium/rustler)
- rustler_precompiled 0.10.1 released 2026-10-24 (0.10.0 2026-09-29); 9.6M downloads; Rustler supports loading precompiled artifacts via `:skip_compilation?` + `:load_from` — [hex.pm API](https://hex.pm/api/packages/rustler_precompiled); [Rustler v0.38.0 docs](https://rustler.hexdocs.pm/Rustler.html)
- erl_nif: "usually a well-behaving native function is to return to its caller within 1 millisecond"; long NIFs degrade VM responsiveness, "can cause miscellaneous strange behaviors" and poor load balancing; dirty NIFs (`ERL_NIF_DIRTY_JOB_CPU_BOUND` / `ERL_NIF_DIRTY_JOB_IO_BOUND`) avoid the time limit, but misclassification can starve ordinary schedulers; a crashing NIF takes down the entire VM — [Erlang erl_nif docs](https://www.erlang.org/doc/apps/erts/erl_nif.html)
- Elixir blog "Interoperability in 2025: beyond the Erlang VM" (2025-08-18) covers interop options — [elixir-lang.org blog index](https://elixir-lang.org/blog/)

### Inferences
- Rustler converts Rust panics into Erlang exceptions (a well-known Rustler feature, not re-verified here), but segfaults/aborts in unsafe code or C deps still kill the node — a real risk if wrapping crypto or HTTP/2 crates.
- Since every b4hub feature has a native Elixir equivalent (WebAuthn via Wax, JWT via JOSE, AES-GCM via `:crypto`, HTTP/2 via Mint), NIFs are not needed for functionality; they would only be a hedge (e.g. reuse `webauthn-rs` instead of single-maintainer Wax) at the cost of a Rust toolchain in the Docker build (mitigated by `rustler_precompiled`).
- A Rust sidecar in the same ECS task (talking over localhost HTTP or a Unix socket) or an Erlang Port isolates crashes completely and lets existing `b4hub-core` code be reused, at the cost of an extra container and a serialization boundary.

### Gaps
- Did not fetch Rustler's own guide on panic handling and `#[rustler::nif(schedule = "DirtyCpu")]` for a direct citation.
- Did not find case studies of Elixir services running Rust sidecars on ECS.
