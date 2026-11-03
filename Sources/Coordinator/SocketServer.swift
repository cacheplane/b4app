import Foundation
import NIOCore
import NIOExtras
import NIOPosix
import Synchronization
import WorkspaceProtocol

/// NIO server on the coordinator's Unix socket: hello on connect, events fanned out, commands routed.
public final class SocketServer: Sendable {
  private let group: MultiThreadedEventLoopGroup
  private let serverChannel: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>
  private let acceptTask: Task<Void, Never>
  private let closeTask = Mutex<Task<Void, Never>?>(nil)
  public let socketPath: String

  private init(
    group: MultiThreadedEventLoopGroup,
    serverChannel: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>,
    acceptTask: Task<Void, Never>, socketPath: String
  ) {
    self.group = group
    self.serverChannel = serverChannel
    self.acceptTask = acceptTask
    self.socketPath = socketPath
  }

  public static func start(
    socketPath: String, router: Router, eventLog: EventLog
  ) async throws -> SocketServer {
    let logger = Log.logger("socket")
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let serverChannel: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>
    do {
      serverChannel = try await ServerBootstrap(group: group)
        .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
        .bind(unixDomainSocketPath: socketPath, cleanupExistingSocketFile: true) { channel in
          channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineBasedFrameDecoder()))
            return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
          }
        }
    } catch {
      try? await group.shutdownGracefully()
      throw WorkspaceError(.internalError, "Could not listen on \(socketPath): \(error)")
    }
    chmod(socketPath, 0o600)
    let acceptTask = Task {
      do {
        try await serverChannel.executeThenClose { inbound in
          try await withThrowingDiscardingTaskGroup { connections in
            for try await connection in inbound {
              connections.addTask { await Self.serve(connection, router: router, eventLog: eventLog) }
            }
          }
        }
      } catch {
        logger.info("accept loop ended: \(String(describing: error), privacy: .public)")
      }
    }
    logger.info("listening at \(socketPath, privacy: .public)")
    return SocketServer(
      group: group, serverChannel: serverChannel, acceptTask: acceptTask, socketPath: socketPath)
  }

  private static func serve(
    _ channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>, router: Router, eventLog: EventLog
  ) async {
    do {
      try await channel.executeThenClose { inbound, outbound in
        let hello = HelloEnvelope(
          epoch: eventLog.epoch, sequence: await eventLog.sequence,
          coordinator: CoordinatorIdentity(
            version: CoordinatorVersion.current, pid: ProcessInfo.processInfo.processIdentifier))
        try await outbound.write(ByteBuffer(bytes: try NDJSON.encodeLine(hello)))
        let events = await eventLog.subscribe()
        try await withThrowingTaskGroup(of: Void.self) { group in
          group.addTask {
            for await envelope in events {
              try await outbound.write(ByteBuffer(bytes: try NDJSON.encodeLine(envelope)))
            }
          }
          group.addTask {
            for try await buffer in inbound {
              guard
                let response = await Self.dispatch(
                  line: Data(buffer.readableBytesView), router: router), !Task.isCancelled
              else { return }
              try await outbound.write(ByteBuffer(bytes: try NDJSON.encodeLine(response)))
            }
          }
          _ = try await group.next()
          group.cancelAll()
        }
      }
    } catch {
      // Client went away; nothing to do. Active work never depends on a viewer.
    }
  }

  /// Disconnecting a viewer cancels its wait, even if an external call ignores cancellation.
  /// The command may still finish (as before); its task owns no NIO channel or writer, so a late
  /// result cannot schedule work on an event loop whose connection has already been closed.
  private static func dispatch(line: Data, router: Router) async -> ResponseEnvelope? {
    let reply = SocketReply()
    let work = Task { [line, router, reply] in
      reply.resolve(await router.dispatch(line: line))
    }
    return await withTaskCancellationHandler {
      await reply.value()
    } onCancel: {
      work.cancel()
      reply.resolve(nil)
    }
  }

  public func close() async {
    let closing = closeTask.withLock { task in
      if let task { return task }
      let closing = Task { [acceptTask, serverChannel, group, socketPath] in
        acceptTask.cancel()
        try? await serverChannel.channel.close()
        // The accept task owns the per-connection scopes too. They must unwind before
        // the shared event loop is shut down, including when clients are still connected.
        await acceptTask.value
        try? await group.shutdownGracefully()
        try? FileManager.default.removeItem(atPath: socketPath)
      }
      task = closing
      return closing
    }
    await closing.value
  }
}

/// A single reply or a cancelled wait. Late results are discarded without retaining any I/O state.
private final class SocketReply: Sendable {
  private struct State {
    var resolved = false
    var response: ResponseEnvelope?
    var waiter: CheckedContinuation<ResponseEnvelope?, Never>?
  }
  private let state = Mutex(State())

  func resolve(_ response: ResponseEnvelope?) {
    let waiter = state.withLock { state -> CheckedContinuation<ResponseEnvelope?, Never>? in
      guard !state.resolved else { return nil }
      state.resolved = true
      state.response = response
      defer { state.waiter = nil }
      return state.waiter
    }
    waiter?.resume(returning: response)
  }

  func value() async -> ResponseEnvelope? {
    await withCheckedContinuation { continuation in
      let ready = state.withLock { state in
        if state.resolved { return (true, state.response) }
        state.waiter = continuation
        return (false, nil as ResponseEnvelope?)
      }
      if ready.0 { continuation.resume(returning: ready.1) }
    }
  }
}
