## 2026-11-02 (M8c relay build)

- **D-080 Shared client and storage changes.** `Sources/WorkspaceClient`, `Sources/Coordinator`, `Sources/WorkspaceMirror`.
  - **`WorkspaceClient.resetCursor`** no longer moves a cursor back within the same epoch. This also applies to the Mac, where it fixes a real bug: a snapshot refresh during streaming read the next event as a gap and re-reconciled. The model now subscribes to events before its first snapshot on both platforms.
  - **Storage.** A local B4 connection creates an automatic project for its server folder (as a thread's folder already does), so a phone has a project to start in. `connections.projectId` is backfilled on every coordinator start (a no-op once set) and rewritten when the connection's folder moves to another project. The mirror's schema is v3, adding the index `displayItems("threadId","nativeItemId")` that live deltas search by.
