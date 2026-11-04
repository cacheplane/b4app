## 2026-10-30

- **D-002 Claude Code is driven through the CLI's stream-json stdio protocol, not the TypeScript Agent SDK.** The SDK is a thin stdio client of the same CLI; its control protocol (`control_request` / `control_response`, `initialize`, `can_use_tool`, `interrupt`) was read from the SDK source and verified by a no-inference handshake against 2.1.282. The protocol is undocumented and version-coupled, so the tested CLI version is pinned and re-diffed on upgrade. See `docs/research/2026-10-30-claude-cli-stream-protocol.md`.
