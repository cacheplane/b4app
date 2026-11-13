## 2026-11-12 (the failed mark)

- **D-217 The failed mark is a danger disc with a small cross cut in it.** Amends D-204, where failed was a bare cross in danger.
  - **Why.** The owner read the bare red cross at the end of a row as a button that closes or deletes the thread. Nothing in a thread row is a button, and the mark must not look like one.
  - **What.** `ThreadMark` draws failed as a filled circle in `LLA.Color.danger`, 10.5 of the 12 pt box, with a cross in the background colour from (4.1, 4.1) to (7.9, 7.9), 1.5 wide with round caps. The shape still carries the state without colour: it is the only disc with something cut in it (reply is a plain 8 pt disc, approve a ring with a dot). The tiny row and the iOS widget share the mark and scale it. Its spoken label, "Failed", is unchanged, and so are the badge and the order (`Attention`).
  - **Checked.** `rowShowsEachStateMark` rendered in light and dark and looked at; not checked on a device.
