import Foundation
import Synchronization
import Testing

@testable import WorkspacePlatform

private final class NodeProbeRecords: Sendable {
  private let records = Mutex<[NodeVersionProbeObservation]>([])

  func append(_ observation: NodeVersionProbeObservation) {
    records.withLock { $0.append(observation) }
  }

  func snapshot() -> [NodeVersionProbeObservation] { records.withLock { $0 } }
}

/// Owned files only. The ledger records reached script entries, not kernel process telemetry.
private struct NodeProbeFixture {
  enum Output {
    case fake24, nonVersion, old23

    var line: String {
      switch self {
      case .fake24: "v24.0.0"
      case .nonVersion: "not-a-version"
      case .old23: "v23.0.0"
      }
    }
  }

  let directory: URL
  var path: String { directory.appendingPathComponent("node probe.sh").path }
  var ledger: URL { URL(fileURLWithPath: path + ".probes") }

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "node-probe-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  }

  func writeScript(_ output: Output) throws {
    try Data().write(to: ledger, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledger.path)
    let initiallyEmpty = try Data(contentsOf: ledger).isEmpty
    try #require(initiallyEmpty)
    let script = """
      #!/bin/sh
      printf '%s\\n' probe-entry >> "$0.probes" || exit 71
      [ "$#" -eq 1 ] || exit 72
      [ "$1" = --version ] || exit 73
      printf '%s\\n' '\(output.line)'
      exit 0
      """
    try Data((script + "\n").utf8).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }

  func hasOneReachedEntry() throws -> Bool {
    try Data(contentsOf: ledger) == Data("probe-entry\n".utf8)
  }
}

struct NodeVersionProbeObservationTests {
  @Test func explicitFake24ObservesTheSameSingleProbeAndPreservesSelection() async throws {
    let fixture = try NodeProbeFixture()
    defer { fixture.remove() }
    try fixture.writeScript(.fake24)
    let records = NodeProbeRecords()

    let resolved = await NodeLocator.resolveObservingExplicitProbe(
      environment: ["B4APP_NODE_PATH": fixture.path], observation: { records.append($0) })

    // Keep private path and owned file bytes out of assertion diagnostics.
    let originalPathPreserved = resolved?.path == fixture.path
    #expect(originalPathPreserved)
    let originalVersionPreserved = resolved?.version == "v24.0.0"
    #expect(originalVersionPreserved)
    let explicitSourcePreserved = resolved?.source == "explicit"
    #expect(explicitSourcePreserved)
    let oneReachedEntry = try fixture.hasOneReachedEntry()
    #expect(oneReachedEntry)
    let snapshot = records.snapshot()
    try #require(snapshot.count == 1)
    let observation = try #require(snapshot.first)
    #expect(!observation.commandThrew)
    #expect(observation.selectedOutcomeOrigin == .finished)
    #expect(observation.returnedTimedOut == false)
    #expect(observation.returnedExitCode == 0)
    #expect(observation.returnedSignal == nil)
    #expect(observation.returnedSucceeded == true)
    #expect(observation.stdoutShape == .exactFake24)
    #expect(observation.versionPrefixAccepted == true)
    #expect(observation.minimumAccepted == true)
    #expect(observation.resolveAccepted)
    #expect(!observation.callerCancelledAtReturn)
  }

  @Test func nonVersionRejectsWithoutEvaluatingTheMinimum() async throws {
    let fixture = try NodeProbeFixture()
    defer { fixture.remove() }
    try fixture.writeScript(.nonVersion)
    let records = NodeProbeRecords()

    let resolved = await NodeLocator.resolveObservingExplicitProbe(
      environment: ["B4APP_NODE_PATH": fixture.path], observation: { records.append($0) })

    let rejected = resolved == nil
    #expect(rejected)
    let oneReachedEntry = try fixture.hasOneReachedEntry()
    #expect(oneReachedEntry)
    let snapshot = records.snapshot()
    try #require(snapshot.count == 1)
    let observation = try #require(snapshot.first)
    #expect(!observation.commandThrew)
    #expect(observation.selectedOutcomeOrigin == .finished)
    #expect(observation.returnedTimedOut == false)
    #expect(observation.returnedExitCode == 0)
    #expect(observation.returnedSignal == nil)
    #expect(observation.returnedSucceeded == true)
    #expect(observation.stdoutShape == .other)
    #expect(observation.versionPrefixAccepted == false)
    #expect(observation.minimumAccepted == nil)
    #expect(!observation.resolveAccepted)
  }

  @Test func oldVersionRejectsAtTheOriginalMinimumPredicate() async throws {
    let fixture = try NodeProbeFixture()
    defer { fixture.remove() }
    try fixture.writeScript(.old23)
    let records = NodeProbeRecords()

    let resolved = await NodeLocator.resolveObservingExplicitProbe(
      environment: ["B4APP_NODE_PATH": fixture.path], observation: { records.append($0) })

    let rejected = resolved == nil
    #expect(rejected)
    let oneReachedEntry = try fixture.hasOneReachedEntry()
    #expect(oneReachedEntry)
    let snapshot = records.snapshot()
    try #require(snapshot.count == 1)
    let observation = try #require(snapshot.first)
    #expect(!observation.commandThrew)
    #expect(observation.selectedOutcomeOrigin == .finished)
    #expect(observation.returnedTimedOut == false)
    #expect(observation.returnedExitCode == 0)
    #expect(observation.returnedSignal == nil)
    #expect(observation.returnedSucceeded == true)
    #expect(observation.stdoutShape == .vPrefixOther)
    #expect(observation.versionPrefixAccepted == true)
    #expect(observation.minimumAccepted == false)
    #expect(!observation.resolveAccepted)
  }

  @Test func missingExplicitFileObservesAnErasedThrowWithoutFallback() async throws {
    let fixture = try NodeProbeFixture()
    defer { fixture.remove() }
    let records = NodeProbeRecords()

    let resolved = await NodeLocator.resolveObservingExplicitProbe(
      environment: ["B4APP_NODE_PATH": fixture.path], observation: { records.append($0) })

    let rejected = resolved == nil
    #expect(rejected)
    let snapshot = records.snapshot()
    try #require(snapshot.count == 1)
    let observation = try #require(snapshot.first)
    #expect(observation.commandThrew)
    #expect(observation.selectedOutcomeOrigin == nil)
    #expect(observation.returnedTimedOut == nil)
    #expect(observation.returnedExitCode == nil)
    #expect(observation.returnedSignal == nil)
    #expect(observation.returnedSucceeded == nil)
    #expect(observation.stdoutShape == .unavailable)
    #expect(observation.versionPrefixAccepted == nil)
    #expect(observation.minimumAccepted == nil)
    #expect(!observation.resolveAccepted)
  }
}
