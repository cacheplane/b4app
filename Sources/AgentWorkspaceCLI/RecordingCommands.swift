import ArgumentParser
import Coordinator
import Darwin
import Foundation
import WorkspaceClient

struct DocsRecord: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "docs-record",
    abstract: "Record a fresh B4 thread for documentation review. Type finish to save; EOF aborts.")
  @Option(name: .long, help: "Existing empty B4 thread ID.") var threadId: String
  @Option(name: .long, help: "New absolute private output path; never a public assets directory.") var output:
    String
  @Option(name: .long, help: "Deadline in seconds (1–900).") var maxSeconds: Int = 900

  mutating func validate() throws {
    guard !threadId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      (1...900).contains(maxSeconds), output.hasPrefix("/"),
      !output.split(separator: "/").contains("public"), !output.split(separator: "/").contains(".git")
    else {
      throw ValidationError(
        "Use an empty thread, a private absolute output path, and a deadline of 1–900 seconds.")
    }
  }

  func run() async throws {
    do {
      let link = try await CoordinatorLauncher.ensure()
      let session = RecordingSession(
        client: link.client, threadId: threadId, maxDuration: .seconds(maxSeconds))
      do {
        try await session.start()
        Self.status("Recording ready. Submit in the app; type finish after the conversation settles.")
        let input = RecordingInput()
        input.start()
        while true {
          if let failure = await session.failure { throw failure }
          switch input.command {
          case .pending: try await Task.sleep(for: .milliseconds(50))
          case .abort: throw RecordingFailure.aborted
          case .finish:
            let events = try await session.finish()
            try RecordingOutput.write(events: events, appVersion: CoordinatorVersion.current, path: output)
            Self.status("Recording saved for private review.")
            await link.client.close()
            Foundation.exit(0)
          }
        }
      } catch {
        await session.abort()
        await link.client.close()
        throw error
      }
    } catch {
      // No payloads, paths, endpoint diagnostics, or transcript text in either stream.
      let code =
        (error as? RecordingFailure)?.rawValue ?? (error as? RecordingOutputFailure)?.rawValue
        ?? "unavailable"
      Self.status("Recording stopped [\(code)]. No new recording was published.")
      Foundation.exit(1)
    }
  }

  private static func status(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
  }
}

/// A bounded stdin reader on a blocking utility queue; the async command can
/// still notice its deadline or a lost connection while no input arrives.
private final class RecordingInput: @unchecked Sendable {
  enum Command { case pending, finish, abort }
  private let lock = NSLock()
  private var value: Command = .pending
  var command: Command { lock.withLock { value } }
  func start() {
    DispatchQueue.global(qos: .utility).async { [self] in
      var bytes: [UInt8] = []
      var command: Command = .abort
      while bytes.count < 64 {
        var byte: UInt8 = 0
        let count = Darwin.read(STDIN_FILENO, &byte, 1)
        if count < 0, errno == EINTR { continue }
        guard count == 1 else { break }
        if byte == 10 {
          if String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            == "finish"
          {
            command = .finish
          }
          break
        }
        bytes.append(byte)
      }
      lock.withLock { value = command }
    }
  }
}
