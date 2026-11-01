extension Array where Element == DeviceInfo {
  /// Whether the user's devices list no joined Mac: none with platform `macos` that is not revoked.
  /// An empty list (the phone before its first `GET /v1/devices`) is not a lost host. A Mac that is
  /// joined but asleep still counts; telling those apart is presence (M8c).
  public var hostDisconnected: Bool {
    !isEmpty && !contains { $0.platform == "macos" && $0.revokedAt == nil }
  }
}
