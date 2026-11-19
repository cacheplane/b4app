# Plan

Here is what I will do, **step by step**:

1. Read `Package.swift` and the target list.
2. Add the new target:

   ```swift
   .target(name: "StreamingMarkdown")
   ```

3. Run the tests.

## Notes

- The parser is *append-only*.
  - A committed block never changes.
  - Tables are held until the delimiter row.
- Ids are paths, like `3.1.0`.

> Remember: finish() closes everything.

| Step | Result |
|------|--------|
| build | ok |
| test | **pass** |

Final paragraph with a [link](https://example.com) and trailing text.

---

```
no language
```
