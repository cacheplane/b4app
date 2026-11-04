## 2026-10-31

- **D-020 Parked versus cancelled is decided by `GET /threads/:id/pending_interrupts`, never by the `interrupted` status alone.** B4 writes `interrupted` for both. A non-empty list is a parked prompt: the turn stays `waiting_for_user` across stream loss and coordinator restart, and the prompt is re-opened from the durable `value` under a new adapter generation. An empty list is a cancellation.
