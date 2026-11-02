import Foundation

/// Why a link operation failed. `closed` carries the WebSocket close code the peer (or this end) sent.
public enum HubLinkError: Error, Equatable, Sendable {
  /// The upgrade was answered with this HTTP status instead of `101`.
  case refused(status: Int)
  /// The socket closed with this code.
  case closed(code: Int)
  /// The connection failed some other way.
  case failed(String)
  /// A frame arrived that is not a relay message this build knows. The link is still up.
  case undecodable
  /// `RelayLink.send` with no live link.
  case notConnected
}

/// One open WebSocket to the hub's link endpoint: relay frames in, relay frames out.
public protocol HubLinkSocket: Sendable {
  func send(_ message: RelayMessage) async throws
  /// The next frame. Throws `HubLinkError.undecodable` for a frame to skip, and `.closed(code:)` or
  /// `.failed` once the socket is over.
  func receive() async throws -> RelayMessage
  /// Closes the socket; a pending `receive` throws `.closed(code:)`.
  func close(code: Int)
}

/// Opens the link. A real one speaks WebSocket over `URLSession`; a fake scripts the hub's side.
public protocol HubLinkConnection: Sendable {
  /// Opens `GET /v1/devices/self/link` under the hub URL `url` (an `http(s)` URL) with the bearer
  /// `token` and the `B4-Protocol` header, and returns once the upgrade is accepted. A refused upgrade
  /// throws `HubLinkError.refused(status:)`.
  func open(url: URL, token: String, protocolVersion: Int) async throws -> any HubLinkSocket
}

// MARK: - URLSession

/// `HubLinkConnection` over `URLSessionWebSocketTask`. It never logs and never holds the token beyond
/// the request it builds.
public struct URLSessionHubLinkConnection: HubLinkConnection {
  /// Applied to the upgrade request. Kept above the 30 s dead-link window so that, if URLSession also
  /// treats it as an idle timeout once the socket is open, `RelayLink`'s own silence timer ends a quiet
  /// link first.
  private let requestTimeout: TimeInterval

  public init(requestTimeout: TimeInterval = 35) {
    self.requestTimeout = requestTimeout
  }

  /// The WebSocket URL of a hub's link endpoint: `http` becomes `ws`, `https` becomes `wss`, and the
  /// path is appended to any the hub URL has.
  public static func linkURL(for hubURL: URL) -> URL {
    guard var components = URLComponents(url: hubURL, resolvingAgainstBaseURL: false) else { return hubURL }
    switch components.scheme?.lowercased() {
    case "http": components.scheme = "ws"
    case "https": components.scheme = "wss"
    default: break
    }
    var path = components.path
    while path.hasSuffix("/") { path.removeLast() }
    components.path = path + "/v1/devices/self/link"
    return components.url ?? hubURL
  }

  public func open(url: URL, token: String, protocolVersion: Int) async throws -> any HubLinkSocket {
    var request = URLRequest(url: Self.linkURL(for: url))
    request.timeoutInterval = requestTimeout
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(String(protocolVersion), forHTTPHeaderField: "B4-Protocol")
    let socket = URLSessionHubLinkSocket(request: request)
    do {
      try await socket.awaitOpen()
    } catch {
      // The session retains its delegate until it is invalidated.
      socket.close(code: 1000)
      throw error
    }
    return socket
  }
}

/// One `URLSessionWebSocketTask` and its own session, so the delegate sees only this socket. The
/// delegate callbacks and `receive` run on different threads; `lock` guards the state they share.
final class URLSessionHubLinkSocket: NSObject, HubLinkSocket, URLSessionWebSocketDelegate,
  URLSessionTaskDelegate, @unchecked Sendable
{
  private let lock = NSLock()
  private var session: URLSession?
  private var task: URLSessionWebSocketTask?
  private var openContinuation: CheckedContinuation<Void, any Error>?
  private var openResult: Result<Void, any Error>?
  private var peerCloseCode: Int?
  private var localCloseCode: Int?

  init(request: URLRequest) {
    super.init()
    let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    let task = session.webSocketTask(with: request)
    // The hub's largest frame is 256 KiB; leave room.
    task.maximumMessageSize = 1_048_576
    self.session = session
    self.task = task
    task.resume()
  }

  /// Waits for the upgrade; throws `.refused(status:)` or `.failed`.
  func awaitOpen() async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let ready: Result<Void, any Error>? = lock.withLock {
          if let openResult { return openResult }
          openContinuation = continuation
          return nil
        }
        if let ready { continuation.resume(with: ready) }
      }
    } onCancel: {
      self.close(code: 1000)
    }
  }

  private func finishOpen(_ result: Result<Void, any Error>) {
    let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
      guard openResult == nil else { return nil }
      openResult = result
      defer { openContinuation = nil }
      return openContinuation
    }
    continuation?.resume(with: result)
  }

  func send(_ message: RelayMessage) async throws {
    guard let task = lock.withLock({ self.task }) else { throw HubLinkError.closed(code: 1000) }
    let data = try JSONEncoder().encode(message)
    do {
      try await task.send(.string(String(decoding: data, as: UTF8.self)))
    } catch {
      throw mapped(error)
    }
  }

  func receive() async throws -> RelayMessage {
    guard let task = lock.withLock({ self.task }) else { throw HubLinkError.closed(code: 1000) }
    let frame: URLSessionWebSocketTask.Message
    do {
      frame = try await task.receive()
    } catch {
      throw mapped(error)
    }
    let data: Data
    switch frame {
    case .string(let text): data = Data(text.utf8)
    case .data(let bytes): data = bytes
    @unknown default: throw HubLinkError.undecodable
    }
    do {
      return try JSONDecoder().decode(RelayMessage.self, from: data)
    } catch {
      throw HubLinkError.undecodable
    }
  }

  func close(code: Int) {
    let (task, session) = lock.withLock { () -> (URLSessionWebSocketTask?, URLSession?) in
      if localCloseCode == nil { localCloseCode = code }
      defer {
        self.task = nil
        self.session = nil
      }
      return (self.task, self.session)
    }
    // A client may send 1000 or an application code; anything else is sent as a normal closure.
    let sendable = code == 1000 || (3000...4999).contains(code)
    task?.cancel(
      with: sendable ? (URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure) : .normalClosure,
      reason: nil)
    session?.finishTasksAndInvalidate()
  }

  /// A failure of `send` or `receive`, as the close code when there is one.
  private func mapped(_ error: any Error) -> any Error {
    if error is CancellationError { return error }
    let code = lock.withLock { () -> Int? in
      if let peerCloseCode { return peerCloseCode }
      if let task, task.closeCode != .invalid { return task.closeCode.rawValue }
      return localCloseCode
    }
    if let code { return HubLinkError.closed(code: code) }
    return HubLinkError.failed(
      (error as? URLError).map { "network error \($0.code.rawValue)" } ?? "connection failed")
  }

  // MARK: URLSession delegate

  func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?
  ) {
    finishOpen(.success(()))
  }

  func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
  ) {
    lock.withLock { peerCloseCode = closeCode.rawValue }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
    // Before the upgrade this is the refusal: a non-101 answer shows up here with the response attached.
    if let status = (task.response as? HTTPURLResponse)?.statusCode, status != 101 {
      finishOpen(.failure(HubLinkError.refused(status: status)))
    } else {
      finishOpen(.failure(mapped(error ?? HubLinkError.failed("connection closed"))))
    }
  }
}

// MARK: - Fake

/// Scripts the hub for tests of `RelayLink` and its consumers. `open` succeeds by default, handing the
/// test the hub's side of the new socket through `nextSocket()`; `failNext` and `refuseWith` make the
/// next opens fail instead.
public final class FakeHubLinkConnection: HubLinkConnection, @unchecked Sendable {
  private let lock = NSLock()
  private var scripted: [Result<Void, any Error>] = []
  private let opened = FakeChannel<FakeHubLinkSocket>()
  private var count = 0

  public init() {}

  /// How many times `open` was called, failed or not.
  public var openCount: Int { lock.withLock { count } }

  /// The next `times` opens throw `error`.
  public func failNext(_ error: any Error, times: Int = 1) {
    lock.withLock { scripted.append(contentsOf: Array(repeating: .failure(error), count: times)) }
  }

  /// The next `times` opens are refused with this HTTP status, as an upgrade the hub answers (401 for a bad
  /// token, 429 over the upgrade limit).
  public func refuseWith(status: Int, times: Int = 1) {
    failNext(HubLinkError.refused(status: status), times: times)
  }

  /// The hub's side of the next successfully opened socket, waiting for it.
  public func nextSocket() async -> FakeHubLinkSocket {
    do { return try await opened.next() } catch { preconditionFailure("nextSocket was cancelled") }
  }

  public func open(url: URL, token: String, protocolVersion: Int) async throws -> any HubLinkSocket {
    let failure = lock.withLock { () -> (any Error)? in
      count += 1
      guard !scripted.isEmpty, case .failure(let error) = scripted.removeFirst() else { return nil }
      return error
    }
    if let failure { throw failure }
    let socket = FakeHubLinkSocket(url: url, token: token, protocolVersion: protocolVersion)
    opened.push(socket)
    return socket
  }
}

/// The hub's side of a fake link, and the device's: the device calls `send`, `receive` and `close`
/// through `HubLinkSocket`; a test calls `deliver`, `nextSent` and `closeFromHub`.
public final class FakeHubLinkSocket: HubLinkSocket, @unchecked Sendable {
  public let url: URL
  /// The bearer token the device opened with.
  public let token: String
  public let protocolVersion: Int

  private let lock = NSLock()
  private let toDevice = FakeChannel<RelayMessage?>()
  private let toHub = FakeChannel<RelayMessage>()
  private var deviceClose: Int?
  private var sentLog: [RelayMessage] = []

  init(url: URL, token: String, protocolVersion: Int) {
    self.url = url
    self.token = token
    self.protocolVersion = protocolVersion
  }

  /// The code the device closed with, once it has.
  public var deviceClosedCode: Int? { lock.withLock { deviceClose } }

  /// Every frame the device has sent so far.
  public var sentMessages: [RelayMessage] { lock.withLock { sentLog } }

  // Hub side.

  /// Sends a frame to the device.
  public func deliver(_ message: RelayMessage) { toDevice.push(message) }

  /// Sends a frame the device cannot decode.
  public func deliverUndecodable() { toDevice.push(nil) }

  /// The next frame the device sent, waiting for it.
  public func nextSent() async throws -> RelayMessage { try await toHub.next() }

  /// Closes the link from the hub's end with a WebSocket close code, after the frames already delivered.
  public func closeFromHub(code: Int) { toDevice.fail(HubLinkError.closed(code: code)) }

  // Device side.

  public func send(_ message: RelayMessage) async throws {
    let closed = lock.withLock { () -> Int? in
      if deviceClose == nil { sentLog.append(message) }
      return deviceClose
    }
    if let closed { throw HubLinkError.closed(code: closed) }
    toHub.push(message)
  }

  public func receive() async throws -> RelayMessage {
    guard let message = try await toDevice.next() else { throw HubLinkError.undecodable }
    return message
  }

  public func close(code: Int) {
    let first = lock.withLock { () -> Bool in
      guard deviceClose == nil else { return false }
      deviceClose = code
      return true
    }
    guard first else { return }
    toDevice.fail(HubLinkError.closed(code: code))
    toHub.fail(HubLinkError.closed(code: code))
  }
}

/// An unbounded queue with an async `next`. After `fail`, `next` returns what is already queued and
/// then throws the error.
final class FakeChannel<Element: Sendable>: @unchecked Sendable {
  private struct Waiter {
    var id: Int
    var continuation: CheckedContinuation<Element, any Error>
  }

  private let lock = NSLock()
  private var buffer: [Element] = []
  private var waiters: [Waiter] = []
  private var failure: (any Error)?
  private var nextID = 0
  /// Waits cancelled before they registered.
  private var cancelledEarly: Set<Int> = []

  func push(_ element: Element) {
    let waiter = lock.withLock { () -> Waiter? in
      guard failure == nil else { return nil }
      if waiters.isEmpty {
        buffer.append(element)
        return nil
      }
      return waiters.removeFirst()
    }
    waiter?.continuation.resume(returning: element)
  }

  func fail(_ error: any Error) {
    let pending = lock.withLock { () -> [Waiter] in
      guard failure == nil else { return [] }
      failure = error
      defer { waiters = [] }
      return waiters
    }
    for waiter in pending { waiter.continuation.resume(throwing: error) }
  }

  func next() async throws -> Element {
    let id = lock.withLock { () -> Int in
      nextID += 1
      return nextID
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Element, any Error>) in
        let outcome = lock.withLock { () -> Result<Element, any Error>? in
          // Frames already queued come first, as they would from a socket that had received them.
          if !buffer.isEmpty {
            cancelledEarly.remove(id)
            return .success(buffer.removeFirst())
          }
          if cancelledEarly.remove(id) != nil { return .failure(CancellationError()) }
          if let failure { return .failure(failure) }
          waiters.append(Waiter(id: id, continuation: continuation))
          return nil
        }
        if let outcome { continuation.resume(with: outcome) }
      }
    } onCancel: {
      let waiter = lock.withLock { () -> Waiter? in
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
          cancelledEarly.insert(id)
          return nil
        }
        return waiters.remove(at: index)
      }
      waiter?.continuation.resume(throwing: CancellationError())
    }
  }
}
