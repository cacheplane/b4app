import Darwin
import Foundation
import WorkspaceProtocol

/// Loopback port checks. A port that cannot be bound is reported as in use; nothing is ever probed
/// or signalled to find out who holds it (spec 10.3).
public enum Ports {
  /// False when something is listening on `127.0.0.1:port` (a connect succeeds) or the port cannot
  /// be bound. The connect is how a listener that also set `SO_REUSEADDR`, as Node does, is seen; it
  /// claims nothing and sends nothing.
  public static func isFree(_ port: Int) -> Bool {
    !isListening(port) && (try? bind(port: port)) != nil
  }

  /// A non-blocking connect with a 200 ms poll. Refused means nothing listens; connected means
  /// something does; a timeout (a listener whose backlog is full drops SYNs) counts as listening.
  static func isListening(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if connected == 0 { return true }
    guard errno == EINPROGRESS else { return false }
    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    let ready = poll(&descriptor, 1, 200)
    if ready == 0 { return true }
    guard ready > 0 else { return false }
    var error: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
    return error == 0
  }

  /// Bind port 0, read back the kernel's choice, release it.
  public static func allocate() throws -> Int {
    try bind(port: 0)
  }

  private static func bind(port: Int) throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw WorkspaceError(.internalError, "socket() failed: \(errno)") }
    defer { close(fd) }
    // A Node listener binds with SO_REUSEADDR, so lingering TIME_WAIT sockets are not a conflict; a
    // live listener still is.
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
    }
    guard bound == 0 else {
      throw WorkspaceError(
        .ownedProcessConflict, "Port \(port) is in use.", details: ["port": .number(Double(port))])
    }
    var actual = sockaddr_in()
    var actualLength = length
    let named = withUnsafeMutablePointer(to: &actual) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &actualLength) }
    }
    guard named == 0 else { throw WorkspaceError(.internalError, "getsockname() failed: \(errno)") }
    return Int(in_port_t(bigEndian: actual.sin_port))
  }
}
