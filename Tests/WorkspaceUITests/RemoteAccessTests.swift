import CoreImage
import Foundation
import Testing
import WorkspaceClient
import WorkspaceProtocol

@testable import WorkspaceUI

@MainActor
private func connectedModel(_ transport: ScriptedTransport) async throws -> WorkspaceModel {
  let model = WorkspaceModel(transportProvider: { transport })
  model.connect()
  let link = await model.settledLink()
  try #require(link == .ready, "the model did not connect: \(model.linkMessage ?? "no message")")
  return model
}

private let joined = HubStatus.Result(
  joined: true, url: "https://hub.example.com", deviceId: "dev-mac", deviceName: "Mac", orgSlug: "acme",
  username: "blove", displayName: "Brian Love", unsyncedChanges: 0,
  link: HubLinkStatus(state: .connected, since: "2026-11-01T10:00:00Z"))

private let minted = HubPair.Result(
  url: "https://hub.example.com", code: "K7M2Q9XP", expiresAt: "2026-11-01T10:05:00.000000Z")

/// A flow whose sleeps return at once and whose clock the test moves.
@MainActor
private func flow(_ model: WorkspaceModel, clock: ClockBox = ClockBox()) -> PairingFlow {
  let flow = PairingFlow(model: model)
  flow.sleep = { _ in
    clock.advance(1)
    await Task.yield()
  }
  flow.uptime = { clock.now }
  return flow
}

private final class ClockBox: @unchecked Sendable {
  private let base = ContinuousClock.Instant.now
  private var seconds = 0.0
  func advance(_ by: Double) { seconds += by }
  /// Moves only when the test says so, so a slow machine cannot change the count.
  var now: ContinuousClock.Instant { base.advanced(by: .seconds(seconds)) }
}

@MainActor
@Suite struct RemoteAccessTests {
  // MARK: The link

  @Test func pairLinkPercentEncodesTheHub() throws {
    let link = PairLink.make(url: "https://hub.example.com:8443/base?x=1&y=2#frag", code: "K7M2Q9XP")
    #expect(
      link.absoluteString
        == "b4app://pair?hub=https%3A%2F%2Fhub.example.com%3A8443%2Fbase%3Fx%3D1%26y%3D2%23frag&code=K7M2Q9XP"
    )
    // The hub stays one query value, and decodes back to exactly what went in.
    let parts = try #require(URLComponents(url: link, resolvingAgainstBaseURL: false))
    #expect(parts.scheme == "b4app" && parts.host == "pair")
    #expect(parts.queryItems?.map(\.name) == ["hub", "code"])
    #expect(parts.queryItems?.first?.value == "https://hub.example.com:8443/base?x=1&y=2#frag")
    #expect(parts.queryItems?.last?.value == "K7M2Q9XP")
    #expect(parts.fragment == nil)
  }

  @Test func pairLinkOfAPlainHub() {
    let link = PairLink.make(url: "http://localhost:8080", code: "AAAA2222")
    #expect(link.absoluteString == "b4app://pair?hub=http%3A%2F%2Flocalhost%3A8080&code=AAAA2222")
  }

  // MARK: The QR code

  @Test func qrRoundTripsThroughCIDetector() throws {
    let link = PairLink.make(url: "https://hub.example.com:8443/base?x=1&y=2#frag", code: "K7M2Q9XP")
    let image = try #require(QRCode.image(for: link.absoluteString))
    // Crisp: whole pixels per module, and big enough to scan on screen.
    #expect(image.width == image.height && image.width >= 200)
    let detector = try #require(
      CIDetector(
        ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
    let features = detector.features(in: CIImage(cgImage: image)).compactMap { $0 as? CIQRCodeFeature }
    #expect(features.count == 1)
    #expect(features.first?.messageString == link.absoluteString)
  }

  // MARK: The sheet

  @Test func sheetClosesWhenPaired() async throws {
    let transport = ScriptedTransport()
    transport.setHub(joined)
    transport.setPairing(
      .success(minted),
      statuses: [
        HubPairStatus.Result(state: .waiting), HubPairStatus.Result(state: .waiting),
        HubPairStatus.Result(state: .paired, deviceName: "Brian's iPhone"),
      ])
    let model = try await connectedModel(transport)
    let flow = flow(model)
    await flow.run()

    #expect(flow.phase == .paired("Brian's iPhone"))
    #expect(flow.message == "Paired with Brian's iPhone")
    // It polled until the phone showed up, then stopped.
    #expect(transport.calls(.hubPairStatus).count == 3)
    // The code is gone from the sheet's state once it has been used.
    #expect(flow.code == nil && flow.link == nil)
    // The code is a credential: asked for without an operation id, so nothing caches it.
    #expect(transport.recorded(.hubPair).count == 1)
    #expect(transport.recorded(.hubPair).first?.operationId == nil)
  }

  @Test func sheetShowsTheLinkAndCountsDown() async throws {
    let transport = ScriptedTransport()
    transport.setHub(joined)
    transport.setPairing(.success(minted), statuses: [HubPairStatus.Result(state: .waiting)])
    let model = try await connectedModel(transport)
    let flow = PairingFlow(model: model)
    flow.sleep = { _ in try await Task.sleep(for: .milliseconds(5)) }
    let running = Task { await flow.run() }
    // While waiting the sheet holds the code, the link built from it, and the time left.
    try await waitUntil("the sheet to show the code") { flow.phase == .waiting && flow.secondsLeft != nil }
    #expect(flow.code == "K7M2Q9XP")
    #expect(flow.link == PairLink.make(url: "https://hub.example.com", code: "K7M2Q9XP"))
    #expect((0...300).contains(flow.secondsLeft ?? -1))
    running.cancel()
    await running.value
    flow.clear()
  }

  @Test func anExpiredCodeOffersANewOne() async throws {
    let transport = ScriptedTransport()
    transport.setHub(joined)
    transport.setPairing(
      .success(minted),
      statuses: [HubPairStatus.Result(state: .waiting), HubPairStatus.Result(state: .expired)])
    let model = try await connectedModel(transport)
    let flow = flow(model)
    await flow.run()
    #expect(flow.phase == .expired)
    #expect(flow.code == nil && flow.link == nil)
    #expect(transport.calls(.hubPairStatus).count == 2)

    // "New code" mints again.
    transport.setPairing(
      .success(HubPair.Result(url: minted.url, code: "ZZZZ9999", expiresAt: minted.expiresAt)),
      statuses: [HubPairStatus.Result(state: .paired, deviceName: "Phone")])
    await flow.run()
    #expect(transport.calls(.hubPair).count == 2)
    #expect(flow.phase == .paired("Phone"))
  }

  @Test func theCountdownEndsTheSheetEvenIfStatusStaysWaiting() async throws {
    let transport = ScriptedTransport()
    transport.setHub(joined)
    transport.setPairing(.success(minted), statuses: [HubPairStatus.Result(state: .waiting)])
    let model = try await connectedModel(transport)
    let flow = flow(model)
    await flow.run()
    #expect(flow.phase == .expired)
    #expect(transport.calls(.hubPairStatus).count == 300)
  }

  @Test func closingTheSheetStopsPolling() async throws {
    let transport = ScriptedTransport()
    transport.setHub(joined)
    transport.setPairing(.success(minted), statuses: [HubPairStatus.Result(state: .waiting)])
    let model = try await connectedModel(transport)
    let flow = PairingFlow(model: model)
    flow.sleep = { _ in try await Task.sleep(for: .milliseconds(5)) }
    let running = Task { await flow.run() }
    try await waitUntil("two polls") { transport.calls(.hubPairStatus).count >= 2 }
    running.cancel()
    await running.value
    flow.clear()
    let seen = transport.calls(.hubPairStatus).count
    try await Task.sleep(for: .milliseconds(60))
    #expect(transport.calls(.hubPairStatus).count == seen)
    #expect(flow.code == nil && flow.link == nil)
  }

  @Test func pairDisabledWhenNotJoined() async throws {
    let transport = ScriptedTransport()
    let model = try await connectedModel(transport)
    #expect(model.canPair == false)
    // A sheet opened anyway says why, and never polls.
    let flow = flow(model)
    await flow.run()
    #expect(flow.phase == .notJoined)
    #expect(flow.message == "Join a hub first")
    #expect(transport.calls(.hubPairStatus).isEmpty)

    transport.setHub(joined)
    await model.refreshAccount()
    #expect(model.canPair)
  }

  @Test func aRefusedCodeNamesTheWait() async throws {
    let transport = ScriptedTransport()
    transport.setHub(joined)
    transport.setPairing(
      .failure(
        WorkspaceError(.rateLimited, "Too many codes", details: ["retryAfterMs": .number(1_800_000)])))
    let model = try await connectedModel(transport)
    let flow = flow(model)
    await flow.run()
    guard case .failed(let text) = flow.phase else {
      Issue.record("expected a failure, got \(flow.phase)")
      return
    }
    #expect(text.contains("30 minutes"))
    #expect(!text.contains("K7M2Q9XP"))
  }

  // MARK: Keep awake

  @Test func keepAwakeToggleSendsSettingsUpdate() async throws {
    let transport = ScriptedTransport()
    transport.setHub(joined)
    let model = try await connectedModel(transport)
    await model.refreshRemoteAccess()
    #expect(model.keepAwake == true)

    await model.setKeepAwake(false)
    let calls = transport.recorded(.settingsUpdate)
    #expect(calls.count == 1)
    #expect(calls.first?.params["keepAwake"]?.boolValue == false)
    #expect(calls.first?.operationId != nil)
    #expect(model.keepAwake == false)

    await model.setKeepAwake(true)
    #expect(transport.recorded(.settingsUpdate).count == 2)
    #expect(model.keepAwake == true)
  }

  @Test func aRefusedToggleKeepsTheOldValue() async throws {
    let transport = ScriptedTransport()
    transport.setHub(joined)
    let model = try await connectedModel(transport)
    await model.refreshRemoteAccess()
    transport.setSettings(keepAwake: true, error: WorkspaceError(.internalError, "disk full"))
    await model.setKeepAwake(false)
    #expect(model.keepAwake == true)
    #expect(model.lastError != nil)
  }

  @Test func theLinkStatusComesFromHubStatus() async throws {
    let transport = ScriptedTransport()
    transport.setHub(joined)
    let model = try await connectedModel(transport)
    await model.refreshRemoteAccess()
    #expect(model.hubLink?.state == .connected)
    #expect(RemoteAccessView.linkLine(joined: model.hubJoined, link: model.hubLink) == "Connected to the hub")
    #expect(RemoteAccessView.linkLine(joined: false, link: nil) == "Not joined to a hub")
    #expect(
      RemoteAccessView.linkLine(joined: true, link: HubLinkStatus(state: .connecting))
        == "Connecting to the hub…")
    #expect(
      RemoteAccessView.linkLine(joined: true, link: HubLinkStatus(state: .offline, lastError: "no route"))
        == "Offline: no route")
  }

  @Test func theWordsAreTheOnesTheSpecGave() {
    #expect(
      RemoteAccessView.keepAwakeHelp
        == "While Agent Workspace is joined to a hub, your Mac stays awake so your phone can reach it. The display can still sleep. A Mac with its lid closed on battery power sleeps anyway."
    )
  }
}
