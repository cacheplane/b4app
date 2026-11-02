extension Array where Element == DeviceInfo {
  /// Whether the user's devices list no joined Mac: none with platform `macos` that is not revoked.
  /// An empty list (the phone before its first `GET /v1/devices`) is not a lost host. A Mac that is
  /// joined but asleep still counts; telling those apart is presence (M8c).
  public var hostDisconnected: Bool {
    !isEmpty && !contains { $0.platform == "macos" && $0.revokedAt == nil }
  }
}

extension Array where Element == DeviceInfo {
  /// Whether the account has, or had, a Mac: any device with platform `macos`, revoked or not. A Mac
  /// that left still counts, as the hub counts it when it refuses a merge (`merge_refused`).
  public var hasMac: Bool { contains { $0.platform == "macos" } }

  /// A phone-only account (sign-in plan, Task 15): the list is known (an empty one is a phone that has
  /// not asked yet, so a phone that has a Mac never flashes "Connect your Mac") and holds no Mac.
  public var phoneOnly: Bool { !isEmpty && !hasMac }
}
