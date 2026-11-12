import Foundation
import NIOCore
import NIOExtras
import NIOPosix
import WorkspaceProtocol

/// NIO server on the coordinator's Unix socket: hello on connect, events fanned out, commands routed.
public final class SocketServer: Sendable {
  private let group: MultiThreadedEventLoopGroup
  private let serverChannel: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>
  private let acceptTask: Task<Void, Never>
  private let completion = SocketShutdownCompletion()
  private let observer: SocketShutdownObserver?
  public let socketPath: String

  private init(
    group: MultiThreadedEventLoopGroup,
    serverChannel: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>,
    acceptTask: Task<Void, Never>, socketPath: String, observer: SocketShutdownObserver?
  ) {
    self.group = group
    self.serverChannel = serverChannel
    self.acceptTask = acceptTask
    self.socketPath = socketPath
    self.observer = observer
  }

  public static func start(
    socketPath: String, router: Router, eventLog: EventLog
  ) async throws -> SocketServer {
    try await start(
      socketPath: socketPath, eventLog: eventLog,
      dispatch: { [router] line in await router.dispatch(line: line) })
  }

  /// Internal no-database shutdown controls observe identities only; production supplies no hooks.
  static func start(
    socketPath: String, eventLog: EventLog,
    dispatch: @escaping @Sendable (Data) async -> ResponseEnvelope,
    observer: SocketShutdownObserver? = nil,
    handoff: (@Sendable (ObjectIdentifier) async -> Void)? = nil
  ) async throws -> SocketServer {
    let logger = Log.logger("socket")
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let serverChannel: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>
    do {
      let bootstrap = ServerBootstrap(group: group)
        .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
      if let observer {
        _ = bootstrap.serverChannelInitializer { channel in
          channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(SocketRawAcceptWitness(observer: observer))
          }
        }
      }
      serverChannel = try await bootstrap.bind(
        unixDomainSocketPath: socketPath, cleanupExistingSocketFile: true
      ) { channel in
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineBasedFrameDecoder()))
          let wrapped = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
          observer?(.initialized(ObjectIdentifier(channel)))
          return wrapped
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
            // Finish the source normally and hand off every buffered child before canceling IO.
            // Canceling the accept task can discard a wrapped child before executeThenClose owns it.
            defer { connections.cancelAll() }
            for try await connection in inbound {
              let child = ObjectIdentifier(connection.channel)
              observer?(.dequeued(child))
              await handoff?(child)
              connections.addTask {
                await Self.serve(connection, dispatch: dispatch, eventLog: eventLog)
                observer?(.served(child))
              }
            }
            observer?(.sourceFinished)
          }
        }
      } catch {
        logger.info("accept loop ended: \(String(describing: error), privacy: .public)")
      }
      observer?(.acceptFinished)
    }
    logger.info("listening at \(socketPath, privacy: .public)")
    return SocketServer(
      group: group, serverChannel: serverChannel, acceptTask: acceptTask, socketPath: socketPath,
      observer: observer)
  }

  private static func serve(
    _ channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
    dispatch: @escaping @Sendable (Data) async -> ResponseEnvelope, eventLog: EventLog
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
          defer { group.cancelAll() }
          group.addTask {
            for await envelope in events {
              try await outbound.write(ByteBuffer(bytes: try NDJSON.encodeLine(envelope)))
            }
          }
          group.addTask {
            for try await buffer in inbound {
              let response = await dispatch(Data(buffer.readableBytesView))
              try await outbound.write(ByteBuffer(bytes: try NDJSON.encodeLine(response)))
            }
          }
          _ = try await group.next()
        }
      }
    } catch {
      // Client went away; nothing to do. Active work never depends on a viewer.
    }
  }

  public func close() async {
    await completion.close { [serverChannel, acceptTask, group, socketPath, observer] in
      let listener = serverChannel.channel
      let loop = listener.eventLoop
      // Pinned NIO topology: one loop, empty child options/default nil earlier initializer, and our
      // completed child initializer. Bootstrap queues one child transform hop. M lets current-IO
      // transforms enqueue; nested C follows them. SelectableEventLoop drains immediate task batches
      // to empty before another selector IO phase, including across its 4096-task batch boundary.
      // Multiple child loops, asynchronous initializers or a scheduler change need a new proof.
      let closed: EventLoopFuture<Void> = loop.flatSubmit {
        observer?(.firstCloseTurnExecuting)
        return loop.flatSubmit {
          observer?(.listenerCloseInvoked)
          return listener.close()
        }
      }
      observer?(.firstCloseTurnQueued)
      try? await closed.get()
      // The operation promise can precede channelInactive/source finish; closeFuture cannot.
      try? await listener.closeFuture.get()
      observer?(.listenerClosed)
      await acceptTask.value
      observer?(.groupShutdownStarted)
      try? await group.shutdownGracefully()
      try? FileManager.default.removeItem(atPath: socketPath)
    }
  }
}

private actor SocketShutdownCompletion {
  private var task: Task<Void, Never>?
  func close(_ cleanup: @escaping @Sendable () async -> Void) async {
    if let task { await task.value; return }
    let task = Task { await cleanup() }
    self.task = task
    await task.value
  }
}

enum SocketShutdownEvent: Sendable, Equatable {
  case rawRead(ObjectIdentifier), initialized(ObjectIdentifier), dequeued(ObjectIdentifier)
  case served(ObjectIdentifier), sourceFinished, acceptFinished, groupShutdownStarted
  case firstCloseTurnQueued, firstCloseTurnExecuting, listenerCloseInvoked, listenerClosed
}
typealias SocketShutdownObserver = @Sendable (SocketShutdownEvent) -> Void

/// Fixture-only witness before Bootstrap's AcceptHandler; never retains a channel or context.
private final class SocketRawAcceptWitness: ChannelInboundHandler, Sendable {
  typealias InboundIn = Channel
  private let observer: SocketShutdownObserver
  init(observer: @escaping SocketShutdownObserver) { self.observer = observer }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    observer(.rawRead(ObjectIdentifier(Self.unwrapInboundIn(data))))
    context.fireChannelRead(data)
  }
}
