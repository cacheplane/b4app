import Darwin
import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspacePlatform

private func scratchFile(_ name: String) -> String {
  let dir = NSTemporaryDirectory() + "b4mp-\(UUID().uuidString.prefix(8))"
  try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  return dir + "/" + name
}

@Suite struct DotenvTests {
  @Test func dotenvParsesQuotesCommentsAndExports() {
    let env = Dotenv.parse(
      "# c\nexport A=\"va#lue\\n\"\nB='x$y' # trailing\nC=plain#not\nD=\n\nE = spaced \n")
    #expect(env == ["A": "va#lue\n", "B": "x$y", "C": "plain", "D": "", "E": "spaced"])
  }

  @Test func dotenvNeverExpandsAndLastKeyWins() {
    let env = Dotenv.parse("A=1\nB=$A\nA=2\nF=\"a \\\"q\\\" \\\\ b\"")
    #expect(env == ["A": "2", "B": "$A", "F": "a \"q\" \\ b"])
  }
}

@Suite struct ProcessIdentityTests {
  @Test func identityOfSelfAndChild() async throws {
    let me = try #require(ProcessInspector.identity(pid: getpid()))
    #expect(me.pid == getpid())
    #expect(abs(me.startedAt - Date().timeIntervalSince1970) < 3600)
    #expect(!me.arguments.isEmpty)
    let process = try ManagedProcess.spawn(
      executable: "/bin/sleep", arguments: ["5"], environment: ["PATH": "/usr/bin:/bin"],
      workingDirectory: "/", outputPath: scratchFile("sleep.log"))
    let child = try #require(ProcessInspector.identity(pid: process.pid))
    #expect(child == process.identity)
    #expect(child.arguments == ["/bin/sleep", "5"])
    #expect(ProcessInspector.isAlive(pid: process.pid))
    let gone = await ManagedProcess.terminateGroup(pid: process.pid, gracePeriod: .seconds(2))
    #expect(gone)
    #expect(!ProcessInspector.isAlive(pid: process.pid))
    #expect(ProcessInspector.identity(pid: 999_999) == nil)
  }

  @Test func managedProcessWritesOutputToFileAndReportsExit() async throws {
    let log = scratchFile("out.log")
    let process = try ManagedProcess.spawn(
      executable: "/bin/sh", arguments: ["-c", "echo out; echo err >&2; exit 3"],
      environment: ["PATH": "/usr/bin:/bin"], workingDirectory: "/", outputPath: log)
    let deadline = ContinuousClock.now + .seconds(5)
    while process.exitStatus() == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(process.exitStatus() == .exited(3))
    let text = try String(contentsOfFile: log, encoding: .utf8)
    #expect(text.contains("out\n"))
    #expect(text.contains("err\n"))
    let mode = try FileManager.default.attributesOfItem(atPath: log)[.posixPermissions] as? Int
    #expect(mode == 0o600)
  }

  @Test func terminateGroupKillsAGrandchild() async throws {
    let pidFile = scratchFile("grandchild.pid")
    let process = try ManagedProcess.spawn(
      executable: "/bin/sh", arguments: ["-c", "sleep 30 & echo $! > '\(pidFile)'; wait"],
      environment: ["PATH": "/usr/bin:/bin"], workingDirectory: "/", outputPath: scratchFile("g.log"))
    var grandchild: Int32?
    for _ in 0..<50 where grandchild == nil {
      if let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
        let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
      {
        grandchild = pid
      } else {
        try await Task.sleep(for: .milliseconds(50))
      }
    }
    let sleeper = try #require(grandchild)
    #expect(ProcessInspector.isAlive(pid: sleeper))
    #expect(await ManagedProcess.terminateGroup(pid: process.pid, gracePeriod: .seconds(2)))
    try await Task.sleep(for: .milliseconds(200))
    #expect(!ProcessInspector.isAlive(pid: sleeper))
  }

  @Test func spawnOfAMissingExecutableThrows() {
    #expect(throws: WorkspaceError.self) {
      try ManagedProcess.spawn(
        executable: "/nonexistent/bin", arguments: [], environment: [:], workingDirectory: "/",
        outputPath: scratchFile("missing.log"))
    }
  }
}

@Suite struct LogRedactorTests {
  @Test func redactorMasksKeysBearersAndPairs() {
    #expect(LogRedactor.redact("Authorization: Bearer abc.def-ghi") == "Authorization: Bearer [redacted]")
    #expect(LogRedactor.redact("OPENAI_API_KEY=sk-proj-abcdefghij1234") == "OPENAI_API_KEY=[redacted]")
    #expect(LogRedactor.redact("token: xyz123456") == "token: [redacted]")
    #expect(LogRedactor.redact("found sk-abcdefghijklmnop in env") == "found [redacted] in env")
    #expect(
      LogRedactor.redact("B4.run dev ready at http://127.0.0.1:3101")
        == "B4.run dev ready at http://127.0.0.1:3101"
    )
    #expect(LogRedactor.redact("Loaded 1 variable(s) from .env") == "Loaded 1 variable(s) from .env")
  }

  @Test func tailAndBoundKeepTheEnd() throws {
    let log = scratchFile("big.log")
    let handle = FileManager.default.createFile(atPath: log, contents: nil)
    #expect(handle)
    let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: log))
    var chunk = Data()
    for index in 0..<120_000 { chunk.append(Data("line \(index) padding padding padding padding\n".utf8)) }
    try writer.write(contentsOf: chunk)
    try writer.close()
    let before = try FileManager.default.attributesOfItem(atPath: log)[.size] as? Int ?? 0
    #expect(before > 4 << 20)
    try LogRedactor.bound(path: log)
    let after = try FileManager.default.attributesOfItem(atPath: log)[.size] as? Int ?? 0
    #expect(after <= (1 << 20) + 64)
    let tail = try LogRedactor.tail(path: log, lines: 3, afterOffset: nil)
    #expect(tail.lines.count == 3)
    #expect(tail.lines.last == "line 119999 padding padding padding padding")
    #expect(tail.truncated)
    #expect(tail.offset == after)
    let appender = try FileHandle(forWritingTo: URL(fileURLWithPath: log))
    try appender.seekToEnd()
    try appender.write(contentsOf: Data("new one\nnew two\n".utf8))
    try appender.close()
    let more = try LogRedactor.tail(path: log, lines: 200, afterOffset: tail.offset)
    #expect(more.lines == ["new one", "new two"])
    #expect(!more.truncated)
    let missing = try LogRedactor.tail(path: scratchFile("absent.log"), lines: 10, afterOffset: nil)
    #expect(missing.lines.isEmpty && missing.offset == 0)
  }
}

@Suite struct PortsTests {
  @Test func portsAllocateAndDetectInUse() throws {
    let port = try Ports.allocate()
    #expect(port > 1024)
    #expect(Ports.isFree(port))
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    // A Node listener sets SO_REUSEADDR; the probe must still see it.
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    #expect(bound == 0)
    #expect(listen(fd, 1) == 0)
    #expect(!Ports.isFree(port))
    // A listener that never accepts saturates its backlog; the probe must still answer quickly.
    let clock = ContinuousClock()
    let elapsed = clock.measure {
      for _ in 0..<3 { #expect(!Ports.isFree(port)) }
    }
    #expect(elapsed < .seconds(2))
  }
}
