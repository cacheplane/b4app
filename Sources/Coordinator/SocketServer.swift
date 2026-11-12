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
  private let invocations: SocketInvocations
  private let closeCompletion = SocketCloseCompletion()
  private let lifecycleObserver: SocketLifecycleObserver?
  private let acceptanceObserver: SocketAcceptanceObserver?
  public let socketPath: String

  private init(
    group: MultiThreadedEventLoopGroup,
    serverChannel: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>,
    acceptTask: Task<Void, Never>, socketPath: String,
    invocations: SocketInvocations, lifecycleObserver: SocketLifecycleObserver?,
    acceptanceObserver: SocketAcceptanceObserver?
  ) {
    self.group = group
    self.serverChannel = serverChannel
    self.acceptTask = acceptTask
    self.socketPath = socketPath
    self.invocations = invocations
    self.lifecycleObserver = lifecycleObserver
    self.acceptanceObserver = acceptanceObserver
  }

  public static func start(
    socketPath: String, router: Router, eventLog: EventLog
  ) async throws -> SocketServer {
    try await start(
      socketPath: socketPath, router: router, eventLog: eventLog, lifecycleObserver: nil)
  }

  // Observes actual ownership operations without providing lifecycle authority.
  static func start(
    socketPath: String, router: Router, eventLog: EventLog,
    lifecycleObserver: SocketLifecycleObserver?
  ) async throws -> SocketServer {
    try await start(
      socketPath: socketPath, eventLog: eventLog,
      plainDispatch: { [router] line in await router.dispatch(line: line) },
      lifecycleObserver: lifecycleObserver)
  }

  // This internal fixture seam accepts only a plain request/response operation. Its captures must be
  // NIO-free, exactly like the production closure above (Router only).
  static func start(
    socketPath: String, eventLog: EventLog, plainDispatch: @escaping SocketDispatch,
    lifecycleObserver: SocketLifecycleObserver?
  ) async throws -> SocketServer {
    try await start(
      socketPath: socketPath, eventLog: eventLog, plainDispatch: plainDispatch,
      lifecycleObserver: lifecycleObserver, acceptanceObserver: nil)
  }

  // Separate socket-only acceptance witnesses; never passed to plain invocation/dispatch state.
  static func start(
    socketPath: String, eventLog: EventLog, plainDispatch: @escaping SocketDispatch,
    lifecycleObserver: SocketLifecycleObserver?, acceptanceObserver: SocketAcceptanceObserver?
  ) async throws -> SocketServer {
    let logger = Log.logger("socket")
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let serverChannel: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>
    do {
      let bootstrap = ServerBootstrap(group: group)
        .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
      if let acceptanceObserver {
        // Fixture-only parent witness runs before Bootstrap's AcceptHandler/async transform.
        _ = bootstrap.serverChannelInitializer { channel in
          channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(
              SocketAcceptanceParentWitness(observer: acceptanceObserver))
          }
        }
      }
      serverChannel = try await bootstrap.bind(
        unixDomainSocketPath: socketPath, cleanupExistingSocketFile: true
      ) { channel in
        channel.eventLoop.makeCompletedFuture {
          let child = ObjectIdentifier(channel)
          if let acceptanceObserver {
            try channel.pipeline.syncOperations.addHandler(
              SocketAcceptanceActiveWitness(child: child, observer: acceptanceObserver))
          }
          try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineBasedFrameDecoder()))
          let wrapped = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
          acceptanceObserver?(.initialized(child))
          return wrapped
        }
      }
    } catch {
      try? await group.shutdownGracefully()
      throw WorkspaceError(.internalError, "Could not listen on \(socketPath): \(error)")
    }
    chmod(socketPath, 0o600)
    let invocations = SocketInvocations(observer: lifecycleObserver, transition: nil)
    let acceptTask = Task {
      do {
        try await serverChannel.executeThenClose { inbound in
          try await withThrowingDiscardingTaskGroup { connections in
            defer { connections.cancelAll() }
            for try await connection in inbound {
              let connectionID = UUID()
              acceptanceObserver?(
                .dequeued(
                  child: ObjectIdentifier(connection.channel), connectionID: connectionID))
              await lifecycleObserver?(.connectionDequeued(connectionID))
              connections.addTask {
                await Self.serve(
                  connection, connectionID: connectionID, dispatch: plainDispatch, eventLog: eventLog,
                  invocations: invocations)
                await lifecycleObserver?(.connectionFinished(connectionID))
              }
            }
          }
        }
      } catch {
        logger.info("accept loop ended: \(String(describing: error), privacy: .public)")
      }
      // executeThenClose has finished its final channel close here.
      await lifecycleObserver?(.acceptFinished)
    }
    logger.info("listening at \(socketPath, privacy: .public)")
    return SocketServer(
      group: group, serverChannel: serverChannel, acceptTask: acceptTask, socketPath: socketPath,
      invocations: invocations, lifecycleObserver: lifecycleObserver,
      acceptanceObserver: acceptanceObserver)
  }

  private static func serve(
    _ channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>, connectionID: UUID,
    dispatch: @escaping SocketDispatch, eventLog: EventLog, invocations: SocketInvocations
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
            // Cancellation must abandon this future, so a local close can join the watcher.
            // Remote FIN observation still follows NIO's existing read/backpressure behavior.
            try await channel.channel.closeFuture.getAbandoningOnCancel()
          }
          group.addTask {
            for await envelope in events {
              try await outbound.write(ByteBuffer(bytes: try NDJSON.encodeLine(envelope)))
            }
          }
          group.addTask {
            for try await buffer in inbound {
              try Task.checkCancellation()
              guard
                let response = invocations.admit(
                  line: Data(buffer.readableBytesView), connectionID: connectionID, dispatch: dispatch)
              else { throw CancellationError() }
              let resolved = try await response.wait()
              try Task.checkCancellation()
              try await outbound.write(ByteBuffer(bytes: try NDJSON.encodeLine(resolved)))
            }
          }
          _ = try await group.next()
        }
      }
    } catch {
      // Client went away; nothing to do. Active work never depends on a viewer.
    }
  }

  var invocationSnapshot: SocketInvocationSnapshot { invocations.snapshot }

  public func close() async {
    // This synchronous Mutex transition is close's admission boundary, before its first suspension.
    invocations.stopAdmission()
    await closeCompletion.close(observer: lifecycleObserver) {
      [acceptTask, serverChannel, group, socketPath, lifecycleObserver, acceptanceObserver] in
      await lifecycleObserver?(.cleanupStarted)
      let listener = serverChannel.channel
      let loop = listener.eventLoop
      // Pinned topology only: one shared event loop; empty child options/default nil earlier child
      // initializer; our initializer returns a completed future. Bootstrap still queues one child
      // transform hop. First M lets current-IO transforms enqueue; nested C follows all of them on
      // the same loop, with no intervening IO phase. Do not replace this with direct close, cancel
      // the accept Task, or add async initialization without a fresh ownership review.
      let closing: EventLoopFuture<Void> = loop.flatSubmit {
        acceptanceObserver?(.firstCloseTurnExecuting)
        return loop.flatSubmit {
          acceptanceObserver?(.listenerCloseInvoked)
          return listener.close()
        }
      }
      acceptanceObserver?(.firstCloseTurnQueued)
      try? await closing.get()
      // The close operation promise can precede channelInactive/source finish; closeFuture cannot.
      try? await listener.closeFuture.get()
      acceptanceObserver?(.listenerClosed)
      // Normal source finish preserves buffered children for unconditional structured handoff.
      await acceptTask.value
      await lifecycleObserver?(.groupShutdownStarted)
      try? await group.shutdownGracefully()
      try? FileManager.default.removeItem(atPath: socketPath)
      await lifecycleObserver?(.cleanupFinished)
    }
  }
}

// Module-internal operation witness. Production's public entry point supplies nil.
enum SocketLifecycleEvent: Sendable, Equatable {
  case connectionDequeued(UUID)
  case handlerAdmitted(token: UUID, connectionID: UUID)
  case handlerFinished(token: UUID, responseDropped: Bool)
  case connectionFinished(UUID)
  case acceptFinished
  case groupShutdownStarted
  case existingCompletion, cleanupStarted, cleanupFinished
}
typealias SocketLifecycleObserver = @Sendable (SocketLifecycleEvent) async -> Void
typealias SocketDispatch = @Sendable (Data) async -> ResponseEnvelope

// This synchronous observer belongs only to socket acceptance/cleanup, never SocketInvocations.
enum SocketAcceptanceEvent: Sendable, Equatable {
  case rawRead(ObjectIdentifier)
  case rawReadForwarded(ObjectIdentifier)
  case parentReadComplete
  case initialized(ObjectIdentifier)
  case active(ObjectIdentifier)
  case dequeued(child: ObjectIdentifier, connectionID: UUID)
  case firstCloseTurnQueued, firstCloseTurnExecuting, listenerCloseInvoked, listenerClosed
}
typealias SocketAcceptanceObserver = @Sendable (SocketAcceptanceEvent) -> Void

/// Installed only by the internal acceptance fixture. It stores no channel/context.
private final class SocketAcceptanceParentWitness: ChannelInboundHandler, Sendable {
  typealias InboundIn = Channel
  private let observer: SocketAcceptanceObserver
  init(observer: @escaping SocketAcceptanceObserver) { self.observer = observer }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let child = ObjectIdentifier(Self.unwrapInboundIn(data))
    observer(.rawRead(child))
    context.fireChannelRead(data)
    observer(.rawReadForwarded(child))
  }
  func channelReadComplete(context: ChannelHandlerContext) {
    observer(.parentReadComplete)
    context.fireChannelReadComplete()
  }
}

/// Actual activation proof, installed only for the acceptance fixture; payload is identity only.
private final class SocketAcceptanceActiveWitness: ChannelInboundHandler, Sendable {
  typealias InboundIn = ByteBuffer
  private let child: ObjectIdentifier
  private let observer: SocketAcceptanceObserver
  init(child: ObjectIdentifier, observer: @escaping SocketAcceptanceObserver) {
    self.child = child
    self.observer = observer
  }
  func channelActive(context: ChannelHandlerContext) {
    observer(.active(child))
    context.fireChannelActive()
  }
}

private actor SocketCloseCompletion {
  private var task: Task<Void, Never>?
  func close(
    observer: SocketLifecycleObserver?, _ cleanup: @escaping @Sendable () async -> Void
  ) async {
    if let task {
      await observer?(.existingCompletion)
      await task.value
      return
    }
    let closing = Task { await cleanup() }
    task = closing
    await closing.value
  }
}

/// Only plain request/response state crosses into independently owned Router work.
/// This registry and its observer must never retain a channel, writer, or SocketServer.
final class SocketInvocations: Sendable {
  private struct Entry {
    let task: Task<Void, Never>
    let response: SocketResponse
  }
  private struct State {
    var accepting = true
    var entries: [UUID: Entry] = [:]
  }
  private let state = Mutex(State())
  private let observer: SocketLifecycleObserver?
  private let transition: (@Sendable (SocketInvocationEvent) -> Void)?
  init(
    observer: SocketLifecycleObserver?, transition: (@Sendable (SocketInvocationEvent) -> Void)?
  ) {
    self.observer = observer
    self.transition = transition
  }

  var snapshot: SocketInvocationSnapshot {
    state.withLock { SocketInvocationSnapshot(accepting: $0.accepting, tokens: Set($0.entries.keys)) }
  }

  func admit(
    line: Data, connectionID: UUID, dispatch: @escaping SocketDispatch
  ) -> SocketResponse? {
    let admission: (UUID, SocketResponse)? = state.withLock { state in
      guard state.accepting else { return nil }
      let token = UUID()
      let response = SocketResponse(witness: nil)
      // A plain Task preserves task locals and is independent of the socket cancellation tree.
      // Production dispatch captures only Router; fixture dispatch must likewise remain NIO-free.
      let task = Task { [dispatch, line, token, connectionID, response, registry = self] in
        // Acquiring the publishing Mutex ensures state exists before any async observer/dispatch.
        registry.confirmPublication(token)
        await registry.observer?(.handlerAdmitted(token: token, connectionID: connectionID))
        let resolved = await dispatch(line)
        registry.remove(token)
        let dropped = !response.resolve(resolved)
        await registry.observer?(.handlerFinished(token: token, responseDropped: dropped))
      }
      state.entries[token] = Entry(task: task, response: response)
      return (token, response)
    }
    guard let (token, response) = admission else { return nil }
    transition?(.published(token))
    return response
  }

  private func confirmPublication(_ token: UUID) {
    precondition(state.withLock { $0.entries[token] != nil })
  }

  private func remove(_ token: UUID) {
    let removed = state.withLock { $0.entries.removeValue(forKey: token) != nil }
    if removed { transition?(.removed(token)) }
  }

  func stopAdmission() {
    let responses = state.withLock { state in
      state.accepting = false
      return state.entries.values.map(\.response)
    }
    for response in responses { response.abandon() }
  }
}

struct SocketInvocationSnapshot: Sendable {
  let accepting: Bool
  let tokens: Set<UUID>
}
enum SocketInvocationEvent: Sendable, Equatable { case published(UUID), removed(UUID) }

/// Internal observation of the production latch; nil in production. The only suspension seam sits
/// inside the cancellation handler and outside the Mutex, before actual waiter registration.
struct SocketResponseWitness: Sendable {
  let beforeRegistration: (@Sendable () async -> Void)?
  let transition: (@Sendable (SocketResponseEvent) -> Void)?
}
enum SocketResponseResolution: Sendable, Equatable { case buffered, delivered, dropped }
enum SocketResponseEvent: Sendable, Equatable {
  case registered
  case resolved(SocketResponseResolution)
  case abandoned(hadWaiter: Bool)
}

/// One response waiter, resolved or abandoned once. Cancellation never reaches Router.dispatch.
final class SocketResponse: Sendable {
  private enum State {
    case pending
    case waiting(CheckedContinuation<ResponseEnvelope, any Error>)
    case resolved(ResponseEnvelope)
    case abandoned
    case consumed
  }
  private let state = Mutex<State>(.pending)
  private let witness: SocketResponseWitness?
  init(witness: SocketResponseWitness?) { self.witness = witness }

  func wait() async throws -> ResponseEnvelope {
    try await withTaskCancellationHandler {
      await witness?.beforeRegistration?()
      return try await withCheckedThrowingContinuation { continuation in
        let registration: (Result<ResponseEnvelope, any Error>?, SocketResponseEvent?) =
          state.withLock { state in
            if Task.isCancelled {
              switch state {
              case .pending, .resolved:
                state = .abandoned
                return (.failure(CancellationError()), .abandoned(hadWaiter: false))
              case .abandoned:
                return (.failure(CancellationError()), nil)
              case .waiting, .consumed:
                preconditionFailure("A socket response has only one waiter.")
              }
            }
            switch state {
            case .pending:
              state = .waiting(continuation)
              return (nil, .registered)
            case .resolved(let response):
              state = .consumed
              return (.success(response), nil)
            case .abandoned:
              return (.failure(CancellationError()), nil)
            case .waiting, .consumed:
              preconditionFailure("A socket response has only one waiter.")
            }
          }
        if let event = registration.1 { witness?.transition?(event) }
        if let result = registration.0 { continuation.resume(with: result) }
      }
    } onCancel: {
      self.abandon()
    }
  }

  @discardableResult
  func resolve(_ response: ResponseEnvelope) -> Bool {
    let result: (SocketResponseResolution, CheckedContinuation<ResponseEnvelope, any Error>?) =
      state.withLock { state in
        switch state {
        case .pending:
          state = .resolved(response)
          return (.buffered, nil)
        case .waiting(let waiter):
          state = .consumed
          return (.delivered, waiter)
        case .abandoned:
          return (.dropped, nil)
        case .resolved, .consumed:
          preconditionFailure("A handler resolves its response once.")
        }
      }
    witness?.transition?(.resolved(result.0))
    result.1?.resume(returning: response)
    return result.0 != .dropped
  }

  func abandon() {
    let result: (CheckedContinuation<ResponseEnvelope, any Error>?, SocketResponseEvent?) =
      state.withLock { state in
        switch state {
        case .waiting(let waiter):
          state = .abandoned
          return (waiter, .abandoned(hadWaiter: true))
        case .pending, .resolved:
          state = .abandoned
          return (nil, .abandoned(hadWaiter: false))
        case .abandoned, .consumed:
          return (nil, nil)
        }
      }
    if let event = result.1 { witness?.transition?(event) }
    result.0?.resume(throwing: CancellationError())
  }
}
