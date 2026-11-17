import Darwin
import Foundation
import Testing
import WorkspacePlatform

/// Only owned scratch files: no environment mutation, database, subprocess or signals.
struct AgentProtocolOwnedPostgresLogTests {
  private typealias Log = AgentProtocolOwnedPostgresLog
  private typealias Configuration = Log.Configuration
  private let pid: Int32 = 27182

  private struct Scratch {
    let root: String
    init() throws {
      let base = try AgentProtocolResourceFixture.physicalExistingDirectory(NSTemporaryDirectory())
      root = base + "/owned-pg-log-" + UUID().uuidString
      try FileManager.default.createDirectory(
        atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func remove() {
      try? FileManager.default.removeItem(atPath: root)
      #expect(!FileManager.default.fileExists(atPath: root))
    }
    func directory(_ suffix: String) throws -> String {
      let path = root + "/" + suffix
      try FileManager.default.createDirectory(
        atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      return path
    }
    func file(_ path: String, _ text: String = "owned fixture prefix\n") throws {
      try Data(text.utf8).write(to: URL(fileURLWithPath: path))
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
    func append(_ text: String, to path: String) throws {
      let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(text.utf8))
    }
  }

  private func configuration(
    temporary: String?, fallback: String, persistent: String? = nil,
    nonce: String? = nil, privateRoot: String? = nil
  ) -> Configuration {
    Configuration(
      persistentDirectory: persistent, temporaryDirectory: temporary,
      foundationTemporaryDirectory: fallback, nonce: nonce, privateRoot: privateRoot,
      processIdentifier: pid)
  }
  private func endpoint(log: String, socket: String) -> PostgresEndpoint {
    PostgresEndpoint(socketDir: socket, dataDir: nil, logPath: log)
  }
  private func processEndpoint(_ scratch: Scratch, temporary: String) throws -> PostgresEndpoint {
    let logDirectory = temporary + "/b4pg-shared-\(pid)"
    let socket = temporary + "/b4pgs-\(pid)"
    try FileManager.default.createDirectory(
      atPath: logDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createDirectory(
      atPath: socket, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let log = logDirectory + "/postgres.log"
    try scratch.file(log)
    return endpoint(log: log, socket: socket)
  }
  private func refused(
    _ expected: Log.Failure = .unsafeLog, _ body: () throws -> Void
  ) {
    do {
      try body()
      Issue.record("An unowned or unsafe fixture log was accepted.")
    } catch let failure as Log.Failure {
      #expect(failure == expected)
      let safe = (failure as NSError).userInfo[NSUnderlyingErrorKey] == nil
      #expect(safe)
    } catch {
      Issue.record("A fixture log failure escaped its static safe category.")
    }
  }

  @Test func configuredPersistentRootAcceptsExactLogAndSocket() throws {
    let scratch = try Scratch(); defer { scratch.remove() }
    let root = try scratch.directory("persistent"), path = root + "/postgres.log"
    try scratch.file(path)
    let config = configuration(temporary: nil, fallback: scratch.root, persistent: root)
    let log = try Log(endpoint(log: path, socket: root), configuration: config)
    let nonempty = try log.offset() > 0
    #expect(nonempty)
  }

  @Test func trustedRootAliasResolvesButDoesNotFollowLogLeaf() throws {
    let scratch = try Scratch(); defer { scratch.remove() }
    let root = try scratch.directory("persistent"), alias = scratch.root + "/trusted-alias"
    try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: root)
    try scratch.file(root + "/postgres.log")
    let config = configuration(temporary: nil, fallback: scratch.root, persistent: alias + "/")
    let log = try Log(endpoint(log: alias + "/postgres.log", socket: alias), configuration: config)
    let nonempty = try log.offset() > 0
    #expect(nonempty)
    try FileManager.default.moveItem(atPath: root + "/postgres.log", toPath: root + "/real-log")
    try FileManager.default.createSymbolicLink(
      atPath: root + "/postgres.log", withDestinationPath: root + "/real-log")
    refused { _ = try Log(endpoint(log: alias + "/postgres.log", socket: alias), configuration: config) }
    refused { _ = try log.offset() }
  }

  @Test func processLayoutUsesConfiguredTemporaryInsteadOfFoundationFallback() throws {
    let scratch = try Scratch(); defer { scratch.remove() }
    let temporary = try scratch.directory("selected"), other = try scratch.directory("foundation")
    let selected = try processEndpoint(scratch, temporary: temporary)
    let wrong = try processEndpoint(scratch, temporary: other)
    let config = configuration(temporary: temporary, fallback: other)
    let log = try Log(selected, configuration: config)
    let nonempty = try log.offset() > 0
    #expect(nonempty)
    refused { _ = try Log(wrong, configuration: config) }
  }

  @Test func processSelectionRejectsAnotherProcessAndAliasedDerivedDirectory() throws {
    let scratch = try Scratch(); defer { scratch.remove() }
    let selected = try processEndpoint(scratch, temporary: scratch.root)
    let config = configuration(temporary: scratch.root, fallback: scratch.root)
    let otherLog = try scratch.directory("b4pg-shared-\(pid + 1)") + "/postgres.log"
    let otherSocket = try scratch.directory("b4pgs-\(pid + 1)")
    try scratch.file(otherLog)
    refused { _ = try Log(endpoint(log: otherLog, socket: otherSocket), configuration: config) }
    let originalRoot = (selected.logPath as NSString).deletingLastPathComponent
    let movedRoot = scratch.root + "/moved-cluster"
    try FileManager.default.moveItem(atPath: originalRoot, toPath: movedRoot)
    try FileManager.default.createSymbolicLink(atPath: originalRoot, withDestinationPath: movedRoot)
    refused { _ = try Log(selected, configuration: config) }
  }

  @Test func emptyPersistentValueUsesProcessAndAbsentTemporaryUsesFoundation() throws {
    let scratch = try Scratch(); defer { scratch.remove() }
    let selected = try processEndpoint(scratch, temporary: scratch.root)
    for persistent in [nil, ""] as [String?] {
      let log = try Log(
        selected,
        configuration: configuration(temporary: nil, fallback: scratch.root, persistent: persistent))
      let nonempty = try log.offset() > 0
      #expect(nonempty)
    }
  }

  @Test func ownedA3UsesOnlyItsPrivateTemporaryProcessLayout() throws {
    let scratch = try Scratch(); defer { scratch.remove() }
    let nonce = "a1b2c3d4e5f6", root = try scratch.directory("b4a3-a1b2c3d4e5f6")
    let temporary = try scratch.directory("b4a3-a1b2c3d4e5f6/tmp")
    let selected = try processEndpoint(scratch, temporary: temporary)
    let config = configuration(
      temporary: temporary, fallback: scratch.root, nonce: nonce, privateRoot: root)
    let log = try Log(selected, configuration: config)
    let nonempty = try log.offset() > 0
    #expect(nonempty)
    refused {
      _ = try Log(
        selected,
        configuration: configuration(
          temporary: scratch.root, fallback: temporary, nonce: nonce, privateRoot: root))
    }
    refused {
      _ = try Log(
        selected,
        configuration: configuration(
          temporary: temporary, fallback: scratch.root, nonce: "invalid", privateRoot: root))
    }
  }

  @Test func ownedNonceAlwaysRefusesNonemptyPersistentSelection() throws {
    let scratch = try Scratch(); defer { scratch.remove() }
    let root = try scratch.directory("b4a3-a1b2c3d4e5f6")
    let temporary = try scratch.directory("b4a3-a1b2c3d4e5f6/tmp")
    let selected = try processEndpoint(scratch, temporary: temporary)
    refused {
      _ = try Log(
        selected,
        configuration: configuration(
          temporary: temporary, fallback: scratch.root, persistent: root,
          nonce: "a1b2c3d4e5f6", privateRoot: root))
    }
    let log = try Log(
      selected,
      configuration: configuration(
        temporary: temporary, fallback: scratch.root, persistent: "",
        nonce: "a1b2c3d4e5f6", privateRoot: root))
    let nonempty = try log.offset() > 0
    #expect(nonempty)
  }

  @Test func endpointLogAndSocketMustBothBelongToSelectedRoot() throws {
    let scratch = try Scratch(); defer { scratch.remove() }
    let root = try scratch.directory("persistent"), other = try scratch.directory("other")
    let path = root + "/postgres.log", otherPath = other + "/postgres.log"
    try scratch.file(path); try scratch.file(otherPath); try scratch.file(root + "/different.log")
    let config = configuration(temporary: nil, fallback: scratch.root, persistent: root)
    for candidate in [
      endpoint(log: otherPath, socket: root), endpoint(log: path, socket: other),
      endpoint(log: otherPath, socket: other), endpoint(log: root + "/different.log", socket: root),
      endpoint(log: "postgres.log", socket: root), endpoint(log: path + "\0suffix", socket: root),
      endpoint(log: path, socket: root + "\0suffix"),
    ] {
      refused { _ = try Log(candidate, configuration: config) }
    }
  }

  @Test func untrustedOrUnavailableConfigurationRootRefusesExistingReadableLog() throws {
    let scratch = try Scratch(); defer { scratch.remove() }
    let path = scratch.root + "/postgres.log"
    try scratch.file(path)
    let selected = endpoint(log: path, socket: scratch.root)
    for root in ["relative", scratch.root + "\0suffix", scratch.root + "/missing", path] {
      refused {
        _ = try Log(
          selected, configuration: configuration(temporary: nil, fallback: scratch.root, persistent: root))
      }
    }
    // An explicitly empty TMPDIR is not an absent TMPDIR in EphemeralPostgres.
    refused {
      _ = try Log(selected, configuration: configuration(temporary: "", fallback: scratch.root))
    }
  }

  @Test func missingAndNonregularLogLeavesRefuseBeforeReading() throws {
    let scratch = try Scratch(); defer { scratch.remove() }
    let path = scratch.root + "/postgres.log"
    let config = configuration(temporary: nil, fallback: scratch.root, persistent: scratch.root)
    let selected = endpoint(log: path, socket: scratch.root)
    refused { _ = try Log(selected, configuration: config) }
    _ = try scratch.directory("postgres.log")
    refused { _ = try Log(selected, configuration: config) }
  }

  @Test func replacedFileIdentityRefusesEverySubsequentOpen() throws {
    let scratch = try Scratch(); defer { scratch.remove() }
    let path = scratch.root + "/postgres.log"
    try scratch.file(path)
    let log = try Log(
      endpoint(log: path, socket: scratch.root),
      configuration: configuration(temporary: nil, fallback: scratch.root, persistent: scratch.root))
    let offset = try log.offset()
    // Keep the captured inode allocated so replacement cannot accidentally recycle it.
    try FileManager.default.moveItem(atPath: path, toPath: scratch.root + "/captured-log")
    try scratch.file(path)
    refused { _ = try log.offset() }
    refused { _ = try log.tail(offset) }
  }

  @Test func shrinkingAndOversizedTailsRefuseButExactLimitIsReadable() throws {
    let scratch = try Scratch(); defer { scratch.remove() }
    let path = scratch.root + "/postgres.log"
    try scratch.file(path)
    let log = try Log(
      endpoint(log: path, socket: scratch.root),
      configuration: configuration(temporary: nil, fallback: scratch.root, persistent: scratch.root))
    let offset = try log.offset()
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    try handle.truncate(atOffset: 0)
    refused(.oversizedLog) { _ = try log.tail(offset) }
    let limit = 4 << 20
    try handle.write(contentsOf: Data(repeating: 0x78, count: limit))
    let exactLimit = try log.tail(0).utf8.count == limit
    #expect(exactLimit)
    try handle.write(contentsOf: Data([0x78]))
    refused(.oversizedLog) { _ = try log.tail(0) }
  }

  @Test func exactTailAndMarkerWitnessExcludeBytesBeforeCapturedOffset() async throws {
    let scratch = try Scratch(); defer { scratch.remove() }
    let path = scratch.root + "/postgres.log", marker = "owned-safe-marker-" + UUID().uuidString
    try scratch.file(path, marker + "\n")
    let log = try Log(
      endpoint(log: path, socket: scratch.root),
      configuration: configuration(temporary: nil, fallback: scratch.root, persistent: scratch.root))
    let offset = try log.offset()
    let initiallyEmpty = try log.tail(offset).isEmpty
    #expect(initiallyEmpty)
    async let observation = log.observed(marker, after: offset)
    try await Task.sleep(for: .milliseconds(30))
    let suffix = "owned appended witness\n" + marker + "\n"
    try scratch.append(suffix, to: path)
    let witnessed = try await observation
    #expect(witnessed)
    let exact = try log.tail(offset) == suffix
    #expect(exact)
    let end = try log.offset()
    let absent = try await log.observed(marker, after: end)
    #expect(!absent)
  }
}
