import Foundation
import Testing
import WorkspacePlatform

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
}
