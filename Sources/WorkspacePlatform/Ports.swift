import Darwin
import Foundation
import WorkspaceProtocol

/// Loopback port checks. A port that cannot be bound is reported as in use; nothing is ever probed
/// or signalled to find out who holds it (spec 10.3).
public enum Ports {
  /// Bind `127.0.0.1:port` and release it. False when the bind fails for any reason.
  public static func isFree(_ port: Int) -> Bool {
    (try? bind(port: port)) != nil
  }

  /// Bind port 0, read back the kernel's choice, release it.
  public static func allocate() throws -> Int {
    try bind(port: 0)
  }

  private static func bind(port: Int) throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw WorkspaceError(.internalError, "socket() failed: \(errno)") }
    defer { close(fd) }
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
