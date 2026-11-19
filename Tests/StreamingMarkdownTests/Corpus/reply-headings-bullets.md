# Review of `SessionService`

## Summary

The service is sound. Three things to look at:

- **Ordering**
  - `appendTurn` runs before `emit`, which is right.
  - `emitDisplayItem` can run twice for one `AdapterEvent`.
    - Guard with the native id.
    - Add a test using `fake-codex.py`.
- **Errors**
  - `WorkspaceError(.unsupportedCapability)` is thrown where a stub exists.
- **Naming**
  - Prefer `threadFolder` over `appFolder` in new code.

## Next

1. Fix the double emit.
2. Add the test.
3. Re-run `swift test`.

Use `swift test --filter SessionServiceTests` for the quick loop.
