import Foundation
import NIOCore
import NIOExtras
import NIOPosix
import WorkspaceClient
import WorkspaceProtocol

/// Unix-domain socket transport using SwiftNIO with newline framing. Used by the macOS app and the CLI.
public final class UnixSocketTransport: WorkspaceTransport, Sendable {
  public let incoming: AsyncStream<Data>
  private let channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>
  private let outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>
  private let group: EventLoopGroup
  private let readerTask: Task<Void, Never>

  private init(channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>, group: EventLoopGroup) async throws {
    self.channel = channel
    self.group = group
    let (stream, continuation) = AsyncStream<Data>.makeStream()
    self.incoming = stream
    // executeThenClose must own the channel's lifetime; the outbound writer is handed out through a box.
    let box = WriterBox()
    let task = Task {
      do {
        try await channel.executeThenClose { inbound, outbound in
          await box.set(outbound)
          for try await buffer in inbound {
            continuation.yield(Data(buffer.readableBytesView))
          }
        }
      } catch {
        // Connection errors end the stream; the client reports endpoint_unavailable.
      }
      continuation.finish()
    }
    self.readerTask = task
    guard let writer = await box.waitForWriter() else {
      task.cancel()
      throw WorkspaceError(.endpointUnavailable, "Socket closed before it became writable.")
    }
    self.outbound = writer
  }

  /// Connect to the coordinator socket. Fails fast with `endpoint_unavailable` when nothing listens.
  public static func connect(
    path: String, timeout: Duration = .seconds(3)
  ) async throws -> UnixSocketTransport {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
      let channel: NIOAsyncChannel<ByteBuffer, ByteBuffer> = try await ClientBootstrap(group: group)
        .connectTimeout(
          TimeAmount.nanoseconds(
            Int64(timeout.components.seconds) * 1_000_000_000
              + Int64(timeout.components.attoseconds / 1_000_000_000))
        )
        .connect(unixDomainSocketPath: path) { channel in
          channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineBasedFrameDecoder()))
            return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
          }
        }
      return try await UnixSocketTransport(channel: channel, group: group)
    } catch let error as WorkspaceError {
      try? await group.shutdownGracefully()
      throw error
    } catch {
      try? await group.shutdownGracefully()
      throw WorkspaceError(.endpointUnavailable, "Could not connect to \(path): \(error)")
    }
  }

  public func send(_ line: Data) async throws {
    var bytes = line
    if bytes.last != 0x0A { bytes.append(0x0A) }
    do {
      try await outbound.write(ByteBuffer(bytes: bytes))
    } catch {
      throw WorkspaceError(.endpointUnavailable, "Socket write failed: \(error)")
    }
  }

  public func close() async {
    outbound.finish()
    readerTask.cancel()
    try? await channel.channel.close()
    try? await group.shutdownGracefully()
  }
}

/// Hands the outbound writer from inside `executeThenClose` to the transport.
private actor WriterBox {
  private var writer: NIOAsyncChannelOutboundWriter<ByteBuffer>?
  private var waiters: [CheckedContinuation<NIOAsyncChannelOutboundWriter<ByteBuffer>?, Never>] = []
  private var finished = false

  func set(_ writer: NIOAsyncChannelOutboundWriter<ByteBuffer>) {
    self.writer = writer
    let waiting = waiters
    waiters = []
    for waiter in waiting { waiter.resume(returning: writer) }
  }

  func waitForWriter() async -> NIOAsyncChannelOutboundWriter<ByteBuffer>? {
    if let writer { return writer }
    if finished { return nil }
    return await withCheckedContinuation { waiters.append($0) }
  }
}

extension UnixSocketTransport {
  /// Convenience: connect and wrap in a client, waiting for the hello.
  public static func client(path: String, timeout: Duration = .seconds(3)) async throws -> WorkspaceClient {
    let transport = try await connect(path: path, timeout: timeout)
    let client = WorkspaceClient(transport: transport)
    let helloTask = Task { try await client.ready() }
    let timer = Task {
      try await Task.sleep(for: timeout)
      helloTask.cancel()
    }
    do {
      _ = try await helloTask.value
      timer.cancel()
      return client
    } catch {
      timer.cancel()
      await client.close()
      throw WorkspaceError(.endpointUnavailable, "No hello from coordinator at \(path).")
    }
  }
}
