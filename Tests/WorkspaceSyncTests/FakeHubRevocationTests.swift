import Testing
import WorkspaceProtocol

@testable import WorkspaceSync

@Suite struct FakeHubRevocationTests {
  @Test(arguments: [false, true])
  func endingTheSessionWakesAnAlreadyParkedPull(deletingAccount: Bool) async throws {
    let hub = FakeHubAPI()
    let reader = Task { try await hub.pull(after: 0, limit: 10, wait: 30) }
    await hub.untilPulling()
    if deletingAccount {
      try await hub.deleteAccount()
    } else {
      try await hub.endSession()
    }
    // A broken fake must fail promptly rather than waiting for the 30-second long-poll deadline.
    // Cancellation produces CancellationError, so it cannot satisfy the required unauthorized error.
    let guardTask = Task {
      try await Task.sleep(for: .seconds(2))
      reader.cancel()
    }
    defer { guardTask.cancel() }
    let error = await #expect(throws: HubError.self) { _ = try await reader.value }
    #expect(error?.code == "unauthorized")
    #expect(error?.status == 401)
    #expect(await hub.parkedPulls == 0)
  }
}
