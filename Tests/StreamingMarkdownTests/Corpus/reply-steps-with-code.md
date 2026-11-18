Here is how to add a retry to the fetch, with the two places that change.

1. **Wrap the call.** In `fetchThread()` replace the direct call with a loop:

   ```swift
   func fetchThread() async throws -> Thread {
     var attempt = 0
     while true {
       do { return try await client.thread() }
       catch where attempt < 3 {
         attempt += 1
         try await Task.sleep(for: .seconds(1 << attempt))
       }
     }
   }
   ```

2. **Make the error retryable.** Mark transient failures:

   ```swift
   extension WorkspaceError { var isTransient: Bool { code == .unavailable } }
   ```

   Then use `isTransient` in the `catch where` clause instead of the counter alone.

3. **Test it** with a fake client that fails twice, then succeeds.

The backoff is 2, 4, 8 seconds; adjust to taste.
