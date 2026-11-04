## 2026-10-31 (M8a)

- **D-045 A turn sent to a thread whose owning device is offline is refused, never queued.** The owner's decision; the refusal names the Mac's last-seen time. The relay (M8c) will route `turn.send`, `turn.interrupt`, and `request.respond` to the owning Mac; interrupts and request answers may be held for at most 60 s, and the first answer wins. Nothing of this is built in M8a, where the phone is read-only.
