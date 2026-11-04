## 2026-11-01 (M8c relay design)

- **D-056 The phone keeps every thread readable when its Mac is unreachable.**
  - **Notice.** After a 60 s grace from the Mac's last-seen time (with "Reconnecting to your Mac…" until then), a notice names the Mac and its last-seen time. The composer, Stop, approvals, and new thread are disabled for that Mac's threads, and a turn still shown as active reads "Not confirmed while your Mac is offline". The owner's direction; the same notice replaces the list-hiding "Host disconnected" screen when the Mac has left the hub.
  - **Scope.** Presence is per Mac. A thread follows its owner, and the list follows the Mac with the most recent activity.
  - *Amended by D-079:* starting a thread is disabled only when the Mac is disconnected, has left the hub, or the phone's own link is down, not during the 60 s "Reconnecting to your Mac…" grace.
