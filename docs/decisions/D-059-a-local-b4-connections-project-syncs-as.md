## 2026-11-01 (M8c relay design)

- **D-059 A local B4 connection's project syncs as `connections.projectId`, a Mac-only column, so the phone can start B4 threads in a project.** It is the owner's decision to include B4. The column holds a project id already on the hub, never a path, and needs no clock. Remote B4 threads belong to no project, so they are continued from the phone but never started there. *Amended by D-080:* a local B4 connection now creates an automatic project for its server folder, and `connections.projectId` is backfilled on every coordinator start.
