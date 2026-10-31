import Foundation
import Testing

@testable import WorkspacePlatform

@Suite struct PathTests {
  @Test func socketLivesInsideRuntimeDirAndIsShort() {
    let paths = PlatformPaths.resolve(environment: ["TMPDIR": NSTemporaryDirectory()])
    #expect((paths.socketPath as NSString).deletingLastPathComponent == paths.runtimeDir)
    #expect(paths.socketPath.utf8.count < 104)
  }

  @Test func honorsEnvironmentOverrides() {
    let paths = PlatformPaths.resolve(environment: [
      "B4APP_RUNTIME_DIR": "/tmp/x", "B4APP_DATA_DIR": "/tmp/y",
    ])
    #expect(paths.lockPath == "/tmp/x/coordinator.lock")
    #expect(paths.databasePath == "/tmp/y/workspace.sqlite")
    #expect(paths.logDir == "/tmp/y/logs")
  }

  @Test func dataDirIsUnderApplicationSupportOnMacOS() {
    #if os(macOS)
      let paths = PlatformPaths.resolve(environment: [:])
      #expect(paths.dataDir.hasSuffix("/Library/Application Support/b4app"))
    #endif
  }

  @Test func privateDirectoryGetsMode0700() throws {
    let dir = NSTemporaryDirectory() + "b4app-test-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try PrivateFiles.ensurePrivateDirectory(dir)
    let mode = try FileManager.default.attributesOfItem(atPath: dir)[.posixPermissions] as? Int
    #expect(mode == 0o700)
  }
}

@Suite struct ExecutableTests {
  @Test func returnsNilForMissingExecutable() {
    #expect(
      ExecutableLocator.find("definitely-not-installed-b4app-xyz", environment: ["PATH": "/usr/bin"]) == nil)
  }

  @Test func rejectsExplicitPathThatIsNotExecutable() {
    #expect(ExecutableLocator.find("sh", explicitPath: NSTemporaryDirectory() + "nope-b4app") == nil)
  }

  @Test func findsShOnPath() {
    let match = ExecutableLocator.find("sh", environment: ["PATH": "/bin:/usr/bin"])
    #expect(match?.path == "/bin/sh")
    #expect(match?.source == .path)
  }

  @Test func runsCommandWithArgumentArrayAndCapturesOutput() async throws {
    let result = try await CommandRunner.run("/bin/sh", ["-c", "printf hi; printf err 1>&2; exit 3"])
    #expect(result.stdout == "hi")
    #expect(result.stderr == "err")
    #expect(result.exitCode == 3)
    #expect(result.timedOut == false)
  }

  @Test func timesOutHungCommand() async throws {
    let result = try await CommandRunner.run(
      "/bin/sh", ["-c", "sleep 30"], options: CommandOptions(timeout: .milliseconds(300)))
    #expect(result.timedOut == true)
  }

  @Test func throwsMissingExecutableWhenItCannotStart() async {
    await #expect(throws: (any Error).self) {
      _ = try await CommandRunner.run("/definitely/missing/binary", [])
    }
  }
}

@Suite struct SecretTests {
  @Test func memoryStoreRoundTripsWithOpaqueRefs() async throws {
    let store = MemorySecretStore()
    let ref = SecretRef.make()
    #expect(ref.rawValue.hasPrefix("secret:"))
    #expect(SecretRef(rawValue: "plain") == nil)
    try await store.put(ref, value: "s3cret")
    #expect(try await store.read(ref) == "s3cret")
    #expect(try await store.remove(ref) == true)
    #expect(try await store.read(ref) == nil)
  }
}

@Suite struct LockTests {
  @Test func secondAcquireSeesHolderWithoutRemovingLock() throws {
    let dir = NSTemporaryDirectory() + "b4app-lock-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/coordinator.lock"
    guard case .acquired(let lock) = try SingletonLock.acquire(path: path, socketPath: "/tmp/s") else {
      Issue.record("expected to acquire")
      return
    }
    // flock is per open file description; a second open descriptor in this process contends like another process.
    guard case .held(let record) = try SingletonLock.acquire(path: path, socketPath: "/tmp/s") else {
      Issue.record("expected the lock to be held")
      return
    }
    #expect(record?.pid == ProcessInfo.processInfo.processIdentifier)
    #expect(FileManager.default.fileExists(atPath: path))
    lock.release()
    #expect(!FileManager.default.fileExists(atPath: path))
    guard case .acquired(let again) = try SingletonLock.acquire(path: path, socketPath: "/tmp/s") else {
      Issue.record("expected to reacquire after release")
      return
    }
    again.release()
  }
}

@Suite struct FallbackDirectoryTests {
  @Test func findsNvmNodeNewestFirstWithoutPath() throws {
    let home = NSTemporaryDirectory() + "b4home-\(UUID().uuidString.prefix(8))"
    for version in ["v22.14.0", "v24.9.0", "v24.20.0", "v12.21.0"] {
      let bin = "\(home)/.nvm/versions/node/\(version)/bin"
      try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
      // A name no real install directory holds, so the assertion is about the nvm order alone
      // (CI runners have Homebrew's `node`, which rightly comes earlier in the list).
      FileManager.default.createFile(
        atPath: bin + "/b4app-fake-node", contents: Data("#!/bin/sh\necho \(version)\n".utf8),
        attributes: [.posixPermissions: 0o755])
    }
    let dirs = ExecutableLocator.fallbackDirectories(home: home)
    #expect(dirs.contains("\(home)/.nvm/versions/node/v24.20.0/bin"))
    #expect(
      dirs.firstIndex(of: "\(home)/.nvm/versions/node/v24.20.0/bin")!
        < dirs.firstIndex(of: "\(home)/.nvm/versions/node/v24.9.0/bin")!)
    #expect(dirs.contains("\(home)/.local/share/fnm/aliases/default/bin"))
    #expect(dirs.last == "/usr/bin")
    let match = ExecutableLocator.find(
      "b4app-fake-node", environment: ["PATH": "/nonexistent", "HOME": home])
    #expect(match?.path == "\(home)/.nvm/versions/node/v24.20.0/bin/b4app-fake-node")
    #expect(match?.source == .fallback)
  }

  @Test func peekReportsOnlyLiveHolders() throws {
    let path = NSTemporaryDirectory() + "b4lock-\(UUID().uuidString.prefix(8))"
    #expect(SingletonLock.peek(path: path) == nil)
    guard case .acquired(let lock) = try SingletonLock.acquire(path: path, socketPath: "/tmp/s.sock") else {
      Issue.record("expected to acquire")
      return
    }
    #expect(SingletonLock.peek(path: path)?.pid == ProcessInfo.processInfo.processIdentifier)
    lock.release()
    #expect(SingletonLock.peek(path: path) == nil)
    // A record left by a dead process reads as nil.
    let stale = LockRecord(pid: 2_147_000_000, startedAt: "x", socketPath: "/tmp/s.sock")
    try JSONEncoder().encode(stale).write(to: URL(fileURLWithPath: path))
    #expect(SingletonLock.peek(path: path) == nil)
  }
}
