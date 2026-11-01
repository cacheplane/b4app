import Darwin
import Foundation
import Synchronization
import Testing
import WorkspaceProtocol

@testable import WorkspacePlatform

private func scratchFile(_ name: String) -> String {
  let dir = NSTemporaryDirectory() + "b4mp-\(UUID().uuidString.prefix(8))"
  try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  return dir + "/" + name
}

/// A one-shot latch a Dispatch handler opens and a test awaits.
private final class Latch: Sendable {
  private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

  func open() {
    let waiters = state.withLock { state in
      state.open = true
      defer { state.waiters = [] }
      return state.waiters
    }
    for waiter in waiters { waiter.resume() }
  }

  func wait() async {
    await withCheckedContinuation { continuation in
      let open = state.withLock { state in
        if !state.open { state.waiters.append(continuation) }
        return state.open
      }
      if open { continuation.resume() }
    }
  }
}

/// Returns once `pid` has exited, on the kernel's exit event (a Dispatch process source; libdispatch
/// reports a process already gone as exited too), or at `timeout`, a guard for a process that never
/// exits. The source is armed before `exited()` is first asked, so an exit in between is not missed.
/// The event comes a moment before the kernel marks the process a zombie, so `exited()` may take a few
/// more turns to agree.
private func waitForExit(pid: Int32, timeout: Duration = .seconds(10), _ exited: () -> Bool) async {
  let latch = Latch()
  let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
  source.setEventHandler { latch.open() }
  source.resume()
  let deadline = ContinuousClock.now + timeout
  let alarm = Task {
    guard (try? await Task.sleep(until: deadline, clock: .continuous)) != nil else { return }
    latch.open()
  }
  defer {
    alarm.cancel()
    source.cancel()
  }
  if !exited() { await latch.wait() }
  while !exited(), ContinuousClock.now < deadline { await Task.yield() }
}

/// The contents of `path` once it exists, re-read on each vnode event of its directory (an entry was
/// added or renamed) rather than on a clock. The writer creates it by rename, so it is whole. The
/// timeout only ends a test whose writer never writes.
private func contentsOnceCreated(_ path: String, timeout: Duration = .seconds(60)) async throws -> String {
  let fd = open((path as NSString).deletingLastPathComponent, O_EVTONLY)
  guard fd >= 0 else { throw WorkspaceError(.internalError, "cannot watch the directory of \(path)") }
  let (changes, sink) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
  let source = DispatchSource.makeFileSystemObjectSource(
    fileDescriptor: fd, eventMask: .write, queue: .global())
  source.setEventHandler { sink.yield() }
  source.setCancelHandler { close(fd) }
  source.resume()
  let deadline = ContinuousClock.now + timeout
  let alarm = Task {
    guard (try? await Task.sleep(until: deadline, clock: .continuous)) != nil else { return }
    sink.yield()
  }
  defer {
    alarm.cancel()
    source.cancel()
  }
  var events = changes.makeAsyncIterator()
  while true {
    if let text = try? String(contentsOfFile: path, encoding: .utf8) { return text }
    guard ContinuousClock.now < deadline else {
      throw WorkspaceError(.internalError, "\(path) never appeared")
    }
    await events.next()
  }
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
    await waitForExit(pid: process.pid) { process.exitStatus() != nil }
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
      executable: "/bin/sh",
      arguments: ["-c", "sleep 30 & echo $! > '\(pidFile).tmp' && mv '\(pidFile).tmp' '\(pidFile)'; wait"],
      environment: ["PATH": "/usr/bin:/bin"], workingDirectory: "/", outputPath: scratchFile("g.log"))
    let text = try await contentsOnceCreated(pidFile)
    let sleeper = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    #expect(ProcessInspector.isAlive(pid: sleeper))
    #expect(await ManagedProcess.terminateGroup(pid: process.pid, gracePeriod: .seconds(2)))
    // The group's SIGTERM reaches the grandchild too; it exits on its own schedule, so await that. The
    // guard stays well under its 30 s sleep, so a grandchild the signal missed still fails here.
    await waitForExit(pid: sleeper) { !ProcessInspector.isAlive(pid: sleeper) }
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

  @Test func redactorMasksHeaderLinesAndUrlParameters() {
    #expect(LogRedactor.redact("Authorization: Basic dXNlcjpwYXNz") == "Authorization: [redacted]")
    #expect(
      LogRedactor.redact("open https://auth.example/cb?code=SECRET&state=xyz&access_token=tok123#frag")
        == "open https://auth.example/cb?code=[redacted]&state=[redacted]&access_token=[redacted]#frag")
    #expect(
      LogRedactor.redact("GET /threads?limit=5&after=abc") == "GET /threads?limit=5&after=abc")
    let payload: JSONValue = [
      "message": "upstream: Bearer abc.def key sk-proj-ABCDEFGHIJKLMNOP",
      "error": ["message": "see https://x.example/?token=t0k3n", "code": 401],
      "status": "failed",
    ]
    let redacted = LogRedactor.redactMessages(in: payload)
    #expect(redacted["message"]?.stringValue == "upstream: Bearer [redacted] key [redacted]")
    #expect(redacted["error"]?["message"]?.stringValue == "see https://x.example/?token=[redacted]")
    #expect(redacted["error"]?["code"]?.numberValue == 401)
    #expect(redacted["status"]?.stringValue == "failed")
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
