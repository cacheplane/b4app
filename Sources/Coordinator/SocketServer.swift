import Foundation
import NIOCore
import NIOExtras
import NIOPosix
import Synchronization
import WorkspaceProtocol

/// NIO server on the coordinator's Unix socket: hello on connect, events fanned out, commands routed.
public final class SocketServer: Sendable {
  private let group: MultiThreadedEventLoopGroup
  private let serverChannel: NIOAsyncChannel<Void, Never>
  private let acceptTask: Task<Void, Never>
  private let connections: Connections
  private let closeTask = Mutex<Task<Void, Never>?>(nil)
  public let socketPath: String

  private init(
    group: MultiThreadedEventLoopGroup,
    serverChannel: NIOAsyncChannel<Void, Never>,
    acceptTask: Task<Void, Never>, connections: Connections, socketPath: String
  ) {
    self.group = group
    self.serverChannel = serverChannel
    self.acceptTask = acceptTask
    self.connections = connections
    self.socketPath = socketPath
  }

  public static func start(
    socketPath: String, router: Router, eventLog: EventLog
  ) async throws -> SocketServer {
    try await start(
      socketPath: socketPath, router: router, eventLog: eventLog,
      beforeAccepting: nil, childActivated: nil)
  }

  /// Internal lifecycle seam: tests can hold accept consumption after a child is initialized.
  static func start(
    socketPath: String, router: Router, eventLog: EventLog,
    beforeAccepting: (@Sendable () async -> Void)?, childActivated: (@Sendable () -> Void)?
  ) async throws -> SocketServer {
    let logger = Log.logger("socket")
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let connections = Connections()
    let serverChannel: NIOAsyncChannel<Void, Never>
    do {
      serverChannel = try await ServerBootstrap(group: group)
        .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
        .bind(unixDomainSocketPath: socketPath, cleanupExistingSocketFile: true) { channel in
          channel.eventLoop.makeCompletedFuture {
            try connections.start(
              channel, router: router, eventLog: eventLog, childActivated: childActivated)
          }
        }
    } catch {
      await connections.close()
      try? await group.shutdownGracefully()
      throw WorkspaceError(.internalError, "Could not listen on \(socketPath): \(error)")
    }
    chmod(socketPath, 0o600)
    let acceptTask = Task {
      if let beforeAccepting { await beforeAccepting() }
      do {
        try await serverChannel.executeThenClose { inbound in
          // The buffer contains only acceptance notifications. Every child already has an owner.
          for try await _ in inbound {}
        }
      } catch {
        logger.info("accept loop ended: \(String(describing: error), privacy: .public)")
      }
      await connections.close()
    }
    logger.info("listening at \(socketPath, privacy: .public)")
    return SocketServer(
      group: group, serverChannel: serverChannel, acceptTask: acceptTask, connections: connections,
      socketPath: socketPath)
  }

  /// Registers each cleanup owner before its initializer can publish into the cancellable stream.
  private final class Connections: Sendable {
    private struct State {
      var sealed = false
      var owners: [UUID: Task<Void, Never>] = [:]
    }
    private let state = Mutex(State())

    func start(
      _ channel: Channel, router: Router, eventLog: EventLog,
      childActivated: (@Sendable () -> Void)?
    ) throws {
      do {
        try state.withLock { state in
          guard !state.sealed else { throw ChannelError.ioOnClosedChannel }
          try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineBasedFrameDecoder()))
          if let childActivated {
            try channel.pipeline.syncOperations.addHandler(ChildActiveProbe(notify: childActivated))
          }
          let connection = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
            wrappingChannelSynchronously: channel)
          let id = UUID()
          state.owners[id] = Task {
            await SocketServer.serve(connection, router: router, eventLog: eventLog)
            self.finished(id)
          }
        }
      } catch {
        channel.close(promise: nil)
        throw error
      }
    }

    private func finished(_ id: UUID) {
      state.withLock { $0.owners[id] = nil }
    }

    func close() async {
      let owners = state.withLock { state in
        state.sealed = true
        return Array(state.owners.values)
      }
      for owner in owners { owner.cancel() }
      for owner in owners { await owner.value }
    }
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

  /// Observes listener closure without waiting for the held accept-consumption test seam.
  func waitForListenerClosure() async {
    try? await serverChannel.channel.closeFuture.get()
  }

  public func close() async {
    let closing = closeTask.withLock { task in
      if let task { return task }
      let closing = Task { [acceptTask, serverChannel, connections, group, socketPath] in
        // Seal admission before cancelling the accept stream. An initializer arriving after this
        // point closes its raw channel without creating an unowned async writer.
        await connections.close()
        acceptTask.cancel()
        try? await serverChannel.channel.close()
        // Both listener and connection scopes finish before their shared event loop shuts down.
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

/// The lifecycle fixture observes activation after NIO has handed the writer to its application.
private final class ChildActiveProbe: ChannelInboundHandler, Sendable {
  typealias InboundIn = ByteBuffer
  let notify: @Sendable () -> Void

  init(notify: @escaping @Sendable () -> Void) { self.notify = notify }

  func channelActive(context: ChannelHandlerContext) {
    context.fireChannelActive()
    notify()
  }
}
