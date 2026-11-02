import Foundation
import Security

/// Opaque reference stored in app metadata. The value never leaves the credential store.
public struct SecretRef: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
  public let rawValue: String

  public init?(rawValue: String) {
    guard rawValue.hasPrefix("secret:"), rawValue.count > 7 else { return nil }
    self.rawValue = rawValue
  }

  public static func make() -> SecretRef {
    SecretRef(rawValue: "secret:\(UUID().uuidString.lowercased())")!
  }

  public var description: String { rawValue }
}

public protocol SecretStore: Sendable {
  func put(_ ref: SecretRef, value: String) async throws
  func read(_ ref: SecretRef) async throws -> String?
  func remove(_ ref: SecretRef) async throws -> Bool
  /// Where values live, for diagnostics; never a value.
  var backend: String { get }
}

extension SecretStore {
  public var backend: String { String(describing: Self.self) }
}

/// Generic-password items under one service name.
///
/// On iOS every item lives in the data-protection keychain under the app's default access group,
/// readable after the first unlock and never migrated to another device; ad hoc signing ("Sign to
/// Run Locally") is enough there (M8a Task 9 gate, Simulator), while an unsigned build fails with
/// -34018.
///
/// On macOS (D-051) a process whose signature claims the shared access group, a Developer ID build
/// whose embedded provisioning profile authorises `<team>.com.cacheplane.b4app.shared`, uses the
/// data-protection keychain in that group, so the app and the coordinator share items and nothing
/// prompts. Everything else (`swift build`, tests, ad hoc packages) has no profile and so no group,
/// and stays in the file-based login keychain. A data-protection store moves an item it does not
/// hold out of the login keychain the first time it is read: read, add to the group, delete the old
/// copy. Reading an old item can prompt once, since the coordinator's signature changed.
///
/// Each call runs on a thread of its own (`KeychainCall`), because a Keychain prompt blocks it until
/// answered (D-052).
public struct KeychainSecretStore: SecretStore {
  public let service: String
  /// The data-protection access group on macOS; nil means the file-based login keychain.
  public let accessGroup: String?

  /// The suffix of the production access group the app and the coordinator share, after the team id.
  public static let sharedGroupSuffix = sharedGroupSuffix(flavorSuffix: "")

  /// The same for a flavour; `flavorSuffix` is `Flavor.keychainGroupSuffix` ("", ".beta", ".local").
  /// The flavour is passed in because `WorkspacePlatform` re-exports this module.
  public static func sharedGroupSuffix(flavorSuffix: String) -> String {
    ".com.cacheplane.b4app\(flavorSuffix).shared"
  }

  /// The claimed group belonging to a flavour, if the signature claims one.
  public static func selectGroup(from claimed: [String], flavorSuffix: String = "") -> String? {
    let suffix = sharedGroupSuffix(flavorSuffix: flavorSuffix)
    return claimed.first { $0.hasSuffix(suffix) }
  }

  public init(service: String = "b4app", accessGroup: String? = nil) {
    self.service = service
    #if os(macOS)
      self.accessGroup = accessGroup
    #else
      self.accessGroup = nil
    #endif
  }

  /// The store for this process: the shared data-protection group when the signature claims it,
  /// the file-based keychain otherwise. The group comes from the process's own entitlement; the
  /// flavour suffix only says which of the claimed groups is this flavour's.
  public static func forCurrentProcess(
    service: String = "b4app", flavorSuffix: String = ""
  ) -> KeychainSecretStore {
    #if os(macOS)
      let group = selectGroup(from: claimedAccessGroups(), flavorSuffix: flavorSuffix)
      return KeychainSecretStore(service: service, accessGroup: group)
    #else
      return KeychainSecretStore(service: service)
    #endif
  }

  #if os(macOS)
    /// The `keychain-access-groups` entitlement of this process's own signature.
    public static func claimedAccessGroups() -> [String] {
      guard let task = SecTaskCreateFromSelf(nil) else { return [] }
      let value = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil)
      return value as? [String] ?? []
    }
  #endif

  public var backend: String {
    #if os(macOS)
      if let accessGroup { return "data-protection keychain (\(accessGroup))" }
      return "login keychain (file-based)"
    #else
      return "data-protection keychain"
    #endif
  }

  private var usesDataProtection: Bool {
    #if os(macOS)
      return accessGroup != nil
    #else
      return true
    #endif
  }

  /// The flag is always explicit: with no flag, a process that claims keychain entitlements reads
  /// the data-protection copy first and deletes from both keychains, so the migration's "delete the
  /// old copy" also removed the copy it had just written (2026-11-01, the owner's hub token).
  func baseQuery(_ ref: SecretRef, dataProtection: Bool) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: ref.rawValue,
      kSecUseDataProtectionKeychain as String: dataProtection,
    ]
    if dataProtection, let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
    return query
  }

  public func put(_ ref: SecretRef, value: String) async throws {
    try await KeychainCall.run { [self] in
      try write(ref, value: value, dataProtection: usesDataProtection)
      if usesDataProtection && accessGroup != nil { _ = try? delete(ref, dataProtection: false) }
    }
  }

  public func read(_ ref: SecretRef) async throws -> String? {
    try await KeychainCall.run { [self] in
      if let value = try copy(ref, dataProtection: usesDataProtection) { return value }
      guard usesDataProtection, accessGroup != nil,
        let legacy = try copy(ref, dataProtection: false)
      else { return nil }
      try write(ref, value: legacy, dataProtection: true)
      _ = try? delete(ref, dataProtection: false)
      return legacy
    }
  }

  public func remove(_ ref: SecretRef) async throws -> Bool {
    try await KeychainCall.run { [self] in
      let removed = try delete(ref, dataProtection: usesDataProtection)
      guard usesDataProtection, accessGroup != nil else { return removed }
      let legacy = (try? delete(ref, dataProtection: false)) ?? false
      return removed || legacy
    }
  }

  private func write(_ ref: SecretRef, value: String, dataProtection: Bool) throws {
    let data = Data(value.utf8)
    var query = baseQuery(ref, dataProtection: dataProtection)
    var update: [String: Any] = [kSecValueData as String: data]
    if dataProtection {
      update[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }
    let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      query[kSecValueData as String] = data
      if dataProtection {
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      }
      let addStatus = SecItemAdd(query as CFDictionary, nil)
      guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    } else if status != errSecSuccess {
      throw KeychainError(status: status)
    }
  }

  private func copy(_ ref: SecretRef, dataProtection: Bool) throws -> String? {
    var query = baseQuery(ref, dataProtection: dataProtection)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
    return String(decoding: data, as: UTF8.self)
  }

  private func delete(_ ref: SecretRef, dataProtection: Bool) throws -> Bool {
    let status = SecItemDelete(baseQuery(ref, dataProtection: dataProtection) as CFDictionary)
    if status == errSecItemNotFound { return false }
    guard status == errSecSuccess else { throw KeychainError(status: status) }
    return true
  }
}

public struct KeychainError: Error, CustomStringConvertible {
  public let status: OSStatus
  public var description: String {
    let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown"
    if status == errSecMissingEntitlement {
      return
        "Keychain error \(status): \(message) The signature does not claim the keychain access group its provisioning profile authorises (D-051)."
    }
    return "Keychain error \(status): \(message)"
  }
}

/// For tests and fixtures only; never used by a real coordinator.
public actor MemorySecretStore: SecretStore {
  private var values: [SecretRef: String] = [:]
  public init() {}
  public func put(_ ref: SecretRef, value: String) async throws { values[ref] = value }
  public func read(_ ref: SecretRef) async throws -> String? { values[ref] }
  public func remove(_ ref: SecretRef) async throws -> Bool { values.removeValue(forKey: ref) != nil }
  public nonisolated var backend: String { "memory" }
}
