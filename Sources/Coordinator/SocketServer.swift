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
              let response = await router.dispatch(line: Data(buffer.readableBytesView))
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

  public func close() async {
    acceptTask.cancel()
    try? await serverChannel.channel.close()
    try? await group.shutdownGracefully()
    try? FileManager.default.removeItem(atPath: socketPath)
  }
}
