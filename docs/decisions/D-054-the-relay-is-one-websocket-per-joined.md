## 2026-11-01 (M8c relay design)

Design `docs/superpowers/specs/2026-11-01-m8c-relay-design.md`, approved by the owner 2026-11-01; plan `docs/superpowers/plans/2026-11-01-m8c-relay.md`. Built 2026-11-02 (see D-075 to D-080 above, which amend these entries where the build changed them).

- **D-054 The relay is one WebSocket per joined device, and it carries commands, replies, presence, and live progress, never state.**
  - **Shape.** `GET /v1/devices/self/link`, authenticated with the device token before the upgrade. A `macos` device is a host and an `ios` or `cli` device is a client. A newer link replaces an older one.
  - **Timings.** Heartbeat every 10 s; a link silent for 30 s is dead. Reconnect with backoff from 1 s to 30 s, and at once on wake and on a network change.
  - **State.** The change log stays the only source of truth: nothing from the relay is written to the mirror, so the relay needs no cursor and a lost frame costs only a moment of streaming. This replaces the M8 design's reconnect-from-a-cursor paragraph for the relay.
  - **Presence.** `last_seen_at` is the last frame heard from the device.
  - *Amended by D-075:* close codes 4000 to 4003, the 1 MiB socket cap, the `B4-Protocol` header, and `last_seen_at` written before the device reads as offline; the reconnect backoff is 1 s doubling to 30 s on the Mac and to 15 s on the phone.
