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
}

/// Generic-password items in the login keychain under one service name. The data-protection keychain
/// (access groups, no prompts) needs a provisioning profile and is adopted with signing in M6. On iOS
/// every item lives in the data-protection keychain, readable after the first unlock and never migrated
/// to another device.
public struct KeychainSecretStore: SecretStore {
  public let service: String

  public init(service: String = "b4app") {
    self.service = service
  }

  private func baseQuery(_ ref: SecretRef) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: ref.rawValue,
    ]
    #if os(iOS)
      query[kSecUseDataProtectionKeychain as String] = true
    #endif
    return query
  }

  public func put(_ ref: SecretRef, value: String) async throws {
    let data = Data(value.utf8)
    var query = baseQuery(ref)
    var update: [String: Any] = [kSecValueData as String: data]
    #if os(iOS)
      update[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    #endif
    let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      query[kSecValueData as String] = data
      #if os(iOS)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      #endif
      let addStatus = SecItemAdd(query as CFDictionary, nil)
      guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    } else if status != errSecSuccess {
      throw KeychainError(status: status)
    }
  }

  public func read(_ ref: SecretRef) async throws -> String? {
    var query = baseQuery(ref)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
    return String(decoding: data, as: UTF8.self)
  }

  public func remove(_ ref: SecretRef) async throws -> Bool {
    let status = SecItemDelete(baseQuery(ref) as CFDictionary)
    if status == errSecItemNotFound { return false }
    guard status == errSecSuccess else { throw KeychainError(status: status) }
    return true
  }
}

public struct KeychainError: Error, CustomStringConvertible {
  public let status: OSStatus
  public var description: String {
    "Keychain error \(status): \((SecCopyErrorMessageString(status, nil) as String?) ?? "unknown")"
  }
}

/// For tests and fixtures only; never used by a real coordinator.
public actor MemorySecretStore: SecretStore {
  private var values: [SecretRef: String] = [:]
  public init() {}
  public func put(_ ref: SecretRef, value: String) async throws { values[ref] = value }
  public func read(_ ref: SecretRef) async throws -> String? { values[ref] }
  public func remove(_ ref: SecretRef) async throws -> Bool { values.removeValue(forKey: ref) != nil }
}
