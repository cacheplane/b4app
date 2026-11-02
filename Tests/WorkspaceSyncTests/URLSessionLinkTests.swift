import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import Testing

@testable import WorkspaceSync

@Suite(.timeLimit(.minutes(1)))
struct URLSessionLinkTests {
  @Test func urlSessionSendsTheBearerAndProtocolHeaders() async throws {
    let server = try await LoopbackHub.start(.echo)
    defer { server.stop() }
    let socket = try await URLSessionHubLinkConnection().open(
      url: server.url, token: "secret-token", protocolVersion: 1)
    defer { socket.close(code: 1000) }

    #expect(try await socket.receive() == LoopbackHub.hello)
    let request = try #require(server.requests.first)
    #expect(request.path == "/v1/devices/self/link")
    #expect(request.headers["authorization"] == "Bearer secret-token")
    #expect(request.headers["b4-protocol"] == "1")
  }

  @Test func theHubURLPathIsKeptAndTheSchemeBecomesWebSocket() throws {
    #expect(
      URLSessionHubLinkConnection.linkURL(for: URL(string: "https://hub.example.com")!).absoluteString
        == "wss://hub.example.com/v1/devices/self/link")
    #expect(
      URLSessionHubLinkConnection.linkURL(for: URL(string: "http://127.0.0.1:8080/prefix/")!).absoluteString
        == "ws://127.0.0.1:8080/prefix/v1/devices/self/link")
  }

  @Test func framesRoundTrip() async throws {
    let server = try await LoopbackHub.start(.echo)
    defer { server.stop() }
    let socket = try await URLSessionHubLinkConnection().open(url: server.url, token: "t", protocolVersion: 1)
    defer { socket.close(code: 1000) }
    _ = try await socket.receive()  // hello

    let watch = RelayMessage.watch(threadId: "thread-1")
    try await socket.send(watch)
    #expect(try await socket.receive() == watch)

    let command = RelayMessage.command(id: "c1", method: .turnSend, params: .object(["text": .string("hi")]))
    try await socket.send(command)
    #expect(try await socket.receive() == command)
  }

  @Test func anUnknownFrameTypeIsUndecodableNotFatal() async throws {
    let server = try await LoopbackHub.start(.echo)
    defer { server.stop() }
    let socket = try await URLSessionHubLinkConnection().open(url: server.url, token: "t", protocolVersion: 1)
    defer { socket.close(code: 1000) }
    _ = try await socket.receive()

    server.sendRaw(#"{"type":"from_the_future"}"#)
    await #expect(throws: HubLinkError.undecodable) { try await socket.receive() }
    server.sendRaw(#"{"type":"ping"}"#)
    #expect(try await socket.receive() == .ping)
  }

  @Test func closeCodeIsReported() async throws {
    let server = try await LoopbackHub.start(.closeAfterHello(4001))
    defer { server.stop() }
    let socket = try await URLSessionHubLinkConnection().open(url: server.url, token: "t", protocolVersion: 1)
    _ = try await socket.receive()  // hello
    await #expect(throws: HubLinkError.closed(code: 4001)) { try await socket.receive() }
  }

  @Test func anUnauthorizedUpgradeIsRefusedWithItsStatus() async throws {
    let server = try await LoopbackHub.start(.refuse(401))
    defer { server.stop() }
    await #expect(throws: HubLinkError.refused(status: 401)) {
      _ = try await URLSessionHubLinkConnection().open(url: server.url, token: "bad", protocolVersion: 1)
    }
  }

  @Test func aRateLimitedUpgradeIsRefusedWithItsStatus() async throws {
    let server = try await LoopbackHub.start(.refuse(429))
    defer { server.stop() }
    await #expect(throws: HubLinkError.refused(status: 429)) {
      _ = try await URLSessionHubLinkConnection().open(url: server.url, token: "t", protocolVersion: 1)
    }
  }

  @Test func closingLocallyEndsAPendingReceive() async throws {
    let server = try await LoopbackHub.start(.echo)
    defer { server.stop() }
    let socket = try await URLSessionHubLinkConnection().open(url: server.url, token: "t", protocolVersion: 1)
    _ = try await socket.receive()
    async let pending: Void = {
      do { _ = try await socket.receive() } catch {}
    }()
    try await Task.sleep(for: .milliseconds(50))
    socket.close(code: 1000)
    await pending
  }
}

/// A minimal WebSocket hub on loopback: it sends a fixed `hello` on every upgrade, records the upgrade
/// request, and then echoes text frames, closes with a code, or refuses the upgrade with a status.
final class LoopbackHub: @unchecked Sendable {
  enum Mode: Sendable {
    case echo
    case closeAfterHello(Int)
    case refuse(Int)
  }

  struct Request: Sendable {
    var path: String
    var headers: [String: String]
  }

  static let hello: RelayMessage = .hello(
    protocol: 1, minClientProtocol: 1, deviceId: "d1", role: .host, heartbeatSeconds: 10,
    hubTime: "2026-11-01T09:30:00.123Z")

  private let group: MultiThreadedEventLoopGroup
  private let channel: any Channel
  private let lock = NSLock()
  private var recorded: [Request] = []
  private var open: [any Channel] = []
  let url: URL

  var requests: [Request] { lock.withLock { recorded } }

  private init(group: MultiThreadedEventLoopGroup, channel: any Channel, port: Int) {
    self.group = group
    self.channel = channel
    self.url = URL(string: "http://127.0.0.1:\(port)")!
  }

  static func start(_ mode: Mode) async throws -> LoopbackHub {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let box = HubBox()
    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { channel in
        let upgrader = NIOWebSocketServerUpgrader(
          shouldUpgrade: { channel, head in
            box.hub?.record(head)
            if case .refuse = mode { return channel.eventLoop.makeSucceededFuture(nil) }
            return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
          },
          upgradePipelineHandler: { channel, _ in
            channel.eventLoop.makeCompletedFuture {
              try channel.pipeline.syncOperations.addHandler(
                LoopbackSocketHandler(mode: mode, hub: box.hub))
            }
          })
        return channel.eventLoop.makeCompletedFuture {
          let sync = channel.pipeline.syncOperations
          try sync.configureHTTPServerPipeline(
            withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }))
          if case .refuse = mode { try sync.addHandler(LoopbackRefusalHandler(mode: mode)) }
        }
      }
    let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
    let port = try #require(channel.localAddress?.port)
    let hub = LoopbackHub(group: group, channel: channel, port: port)
    box.hub = hub
    return hub
  }

  func stop() {
    let channels = lock.withLock { open }
    for channel in channels { channel.close(promise: nil) }
    channel.close(promise: nil)
    group.shutdownGracefully { _ in }
  }

  /// Writes `text` as one text frame on every open connection.
  func sendRaw(_ text: String) {
    let channels = lock.withLock { open }
    for channel in channels {
      channel.eventLoop.execute {
        let buffer = channel.allocator.buffer(string: text)
        channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: buffer), promise: nil)
      }
    }
  }

  fileprivate func record(_ head: HTTPRequestHead) {
    var headers: [String: String] = [:]
    for header in head.headers { headers[header.name.lowercased()] = header.value }
    lock.withLock { recorded.append(Request(path: head.uri, headers: headers)) }
  }

  fileprivate func register(_ channel: any Channel) { lock.withLock { open.append(channel) } }

  /// The bootstrap's initializers need the hub, which needs the bound channel.
  private final class HubBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LoopbackHub?
    var hub: LoopbackHub? {
      get { lock.withLock { value } }
      set { lock.withLock { value = newValue } }
    }
  }
}

private final class LoopbackSocketHandler: ChannelInboundHandler {
  typealias InboundIn = WebSocketFrame
  typealias OutboundOut = WebSocketFrame

  let mode: LoopbackHub.Mode
  let hub: LoopbackHub?

  init(mode: LoopbackHub.Mode, hub: LoopbackHub?) {
    self.mode = mode
    self.hub = hub
  }

  func handlerAdded(context: ChannelHandlerContext) {
    hub?.register(context.channel)
    let text = (try? String(data: JSONEncoder().encode(LoopbackHub.hello), encoding: .utf8)) ?? ""
    write(text, context: context)
    if case .closeAfterHello(let code) = mode {
      var data = context.channel.allocator.buffer(capacity: 2)
      data.write(webSocketErrorCode: .unknown(UInt16(code)))
      context.writeAndFlush(
        wrapOutboundOut(WebSocketFrame(fin: true, opcode: .connectionClose, data: data)), promise: nil)
    }
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let frame = unwrapInboundIn(data)
    switch frame.opcode {
    case .text:
      var payload = frame.unmaskedData
      write(payload.readString(length: payload.readableBytes) ?? "", context: context)
    case .ping:
      context.writeAndFlush(
        wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)), promise: nil)
    case .connectionClose:
      context.close(promise: nil)
    default:
      break
    }
  }

  private func write(_ text: String, context: ChannelHandlerContext) {
    let buffer = context.channel.allocator.buffer(string: text)
    context.writeAndFlush(
      wrapOutboundOut(WebSocketFrame(fin: true, opcode: .text, data: buffer)), promise: nil)
  }
}

/// Answers the requests the upgrade handler passes on, which in these tests are the refused upgrades.
private final class LoopbackRefusalHandler: ChannelInboundHandler, RemovableChannelHandler {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  let mode: LoopbackHub.Mode

  init(mode: LoopbackHub.Mode) { self.mode = mode }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard case .head = unwrapInboundIn(data), case .refuse(let status) = mode else { return }
    var headers = HTTPHeaders()
    headers.add(name: "content-length", value: "0")
    headers.add(name: "connection", value: "close")
    let head = HTTPResponseHead(
      version: .http1_1, status: HTTPResponseStatus(statusCode: status), headers: headers)
    context.write(wrapOutboundOut(.head(head)), promise: nil)
    context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
  }
}
