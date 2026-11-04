## 2026-11-01 (M8c relay design)

- **D-057 Only `ios` and `cli` devices send relayed commands, and only to their own Macs.**
  - **Methods.** Only `turn.send`, `turn.interrupt`, `request.respond`, `thread.start`, and the read-only `turn.lookup`, allowlisted on the hub and again on the Mac.
  - **Target.** Only a non-revoked `macos` device of the same user and org that owns the thread or project. Every miss is a generic `not_found`.
  - **Folders.** `thread.start` runs only in a folder its project lists, or on a local B4 connection serving that project.
  - **Limits.** In memory on the hub: 60 commands a minute per device, 20 sends a minute per user, 4 watched threads per phone, 64 KiB client frames and 256 KiB host frames.
  - **One replica.** The hub's routing state is in memory, so cross-replica routing waits for M8e.
  - *Amended by D-085:* the hub runs on several instances by serving every link of one user on one instance (a claim per user with a heartbeat takeover, a `409 relocated` refusal at the upgrade, and ALB application-cookie stickiness); frames are never forwarded between instances.
  - *Amended by D-076, D-077:* the wire caps are 1 MiB beneath the per-role limits; a missing routing parameter is `not_found`; the Mac also refuses `thread.start` and `turn.lookup` from its local socket and requires a lowercase-UUID `threadId`.
