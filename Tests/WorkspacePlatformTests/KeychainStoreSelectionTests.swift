import Foundation
import Security
import Testing
import WorkspacePlatform

@testable import WorkspaceSecrets

/// Which keychain a process uses (D-051). These never touch keychain items: an unsigned test
/// binary has no profile, so it must stay on the file-based login keychain.
@Suite struct KeychainStoreSelectionTests {
  @Test func anUnsignedProcessUsesTheLoginKeychain() {
    #expect(KeychainSecretStore.claimedAccessGroups().isEmpty)
    let store = KeychainSecretStore.forCurrentProcess()
    #expect(store.accessGroup == nil)
    #expect(store.backend == "login keychain (file-based)")
  }

  @Test func aSharedGroupSelectsTheDataProtectionKeychain() {
    let store = KeychainSecretStore(accessGroup: "ABCDE12345.com.cacheplane.b4app.shared")
    #expect(store.backend == "data-protection keychain (ABCDE12345.com.cacheplane.b4app.shared)")
    #expect("ABCDE12345.com.cacheplane.b4app.shared".hasSuffix(KeychainSecretStore.sharedGroupSuffix))
  }

  /// Without an explicit `false`, an entitled process's legacy delete also removes the
  /// data-protection copy, which lost the hub token on the first migration.
  @Test func everyQueryNamesItsKeychain() throws {
    let store = KeychainSecretStore(accessGroup: "ABCDE12345.com.cacheplane.b4app.shared")
    let ref = try #require(SecretRef(rawValue: "secret:00000000-0000-0000-0000-000000000000"))
    let legacy = store.baseQuery(ref, dataProtection: false)
    #expect(legacy[kSecUseDataProtectionKeychain as String] as? Bool == false)
    #expect(legacy[kSecAttrAccessGroup as String] == nil)
    let current = store.baseQuery(ref, dataProtection: true)
    #expect(current[kSecUseDataProtectionKeychain as String] as? Bool == true)
    #expect(current[kSecAttrAccessGroup as String] as? String == "ABCDE12345.com.cacheplane.b4app.shared")
  }
}
