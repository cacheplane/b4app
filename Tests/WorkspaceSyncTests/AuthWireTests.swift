import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceSync

/// `Tests/Fixtures/sync/auth.json` is read by the hub's Rust suite too (`auth_fixture.rs`): each
/// example is what the hub accepts or answers, so a renamed field breaks one suite or the other.
@Suite struct AuthWireTests {
  private func fixtureURL(file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)")
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/sync/auth.json")
  }

  private func example(_ name: String) throws -> JSONValue {
    let all = try JSONCoding.decoder.decode([String: JSONValue].self, from: Data(contentsOf: fixtureURL()))
    return try #require(all[name], "auth.json has no \"\(name)\"")
  }

  /// Decodes the example into `T` and encodes it again: the result must be the example, key for key.
  @discardableResult
  private func roundTrips<T: Codable>(_ type: T.Type, _ name: String) throws -> T {
    let expected = try example(name)
    let typed = try JSONCoding.decoder.decode(T.self, from: JSONCoding.encoder.encode(expected))
    let encoded = try JSONCoding.decoder.decode(JSONValue.self, from: JSONCoding.encoder.encode(typed))
    #expect(encoded == expected, "\"\(name)\" does not round-trip through \(T.self)")
    return typed
  }

  @Test func configRoundTrips() throws {
    let config = try roundTrips(AuthConfig.self, "config")
    #expect(config.passkeys.rpId == "local.b4.run")
    #expect(config.apple == AuthConfig.Apple(native: false, web: false))
    #expect(config.signup == .open)
  }

  @Test func passkeyBeginRoundTrips() throws {
    let begun = try roundTrips(PasskeyBeginResponse.self, "passkeyBegin")
    #expect(begun.ceremonyId == "c2e88745-66c2-4506-be08-ca0fc040b6d1")
    #expect(begun.authentication["publicKey"]?["rpId"] == "local.b4.run")
    #expect(begun.registration?["publicKey"]?["rp"]?["name"] == "Agent Workspace")
  }

  @Test func passkeyBeginWithoutRegistrationWhenSignupIsClosed() throws {
    let json = Data(#"{"ceremonyId":"c","authentication":{"publicKey":{}}}"#.utf8)
    let begun = try JSONCoding.decoder.decode(PasskeyBeginResponse.self, from: json)
    #expect(begun.registration == nil)
    let encoded = try JSONCoding.decoder.decode(JSONValue.self, from: JSONCoding.encoder.encode(begun))
    #expect(encoded["registration"] == nil)
  }

  @Test func passkeyFinishVariantsRoundTrip() throws {
    let assertion = try roundTrips(PasskeyFinishRequest.self, "passkeyFinishAssertion")
    #expect(assertion.assertion != nil && assertion.attestation == nil)
    #expect(assertion.device.deviceId == "01a19a2b-bbc9-744f-9b64-011001ab330e")

    let attestation = try roundTrips(PasskeyFinishRequest.self, "passkeyFinishAttestation")
    #expect(attestation.attestation != nil && attestation.assertion == nil)
    #expect(attestation.device == DeviceSpec(deviceName: "Brian's iPhone", platform: "ios"))
  }

  @Test func authSessionRoundTrips() throws {
    let session = try roundTrips(AuthSession.self, "authSession")
    #expect(session.needsOnboarding)
    #expect(session.org == OrgInfo(slug: "o-tv5nbqu3", name: "My Org"))
    #expect(session.user == UserInfo(username: "u-afbtapky", displayName: ""))
  }

  @Test func profileRequestRoundTrips() throws {
    #expect(try roundTrips(ProfileRequest.self, "profileRequest").fullName == "Brian Love")
  }

  @Test func meRoundTripsWithIdentities() throws {
    let me = try roundTrips(MeResponse.self, "me")
    #expect(me.user.displayName == "Brian Love" && me.fullName == "Brian Love")
    #expect(me.onboarded)
    #expect(me.identities.map(\.kind) == ["passkey", "apple"])
    #expect(me.identities[0].lastUsedAt == "2026-11-01T10:00:00.000000Z")
    #expect(me.identities[1].lastUsedAt == nil && me.identities[1].name == "x7k2@privaterelay.appleid.com")
  }

  @Test func meKeepsExplicitNullsTheHubSends() throws {
    // Before onboarding the hub answers `fullName: null`; an identity never used has `lastUsedAt: null`
    // and an unnamed one `name: null`. The encoder writes them back as null, not as missing keys.
    let json = Data(
      #"""
      {"deviceId":"d","deviceName":"Mac","platform":"macos","org":{"slug":"o","name":"O"},
       "user":{"username":"u","displayName":"","fullName":null},"createdAt":"2026-11-01T09:00:00.000000Z",
       "onboarded":false,
       "identities":[{"id":"i","kind":"passkey","name":null,"createdAt":"2026-11-01T09:00:00.000000Z","lastUsedAt":null}]}
      """#.utf8)
    let me = try JSONCoding.decoder.decode(MeResponse.self, from: json)
    #expect(me.fullName == nil && !me.onboarded)
    let expected = try JSONCoding.decoder.decode(JSONValue.self, from: json)
    let encoded = try JSONCoding.decoder.decode(JSONValue.self, from: JSONCoding.encoder.encode(me))
    #expect(encoded == expected)
  }

  @Test func meFromAHubBeforeSignInStillDecodes() throws {
    // The enrollment-era answer has none of the account fields; the user counts as onboarded.
    let json = Data(
      #"""
      {"deviceId":"d","deviceName":"Mac","platform":"macos","org":{"slug":"o","name":"O"},
       "user":{"username":"u","displayName":"U"},"createdAt":"2026-10-31T12:00:00.000000Z"}
      """#.utf8)
    let me = try JSONCoding.decoder.decode(MeResponse.self, from: json)
    #expect(me.onboarded && me.fullName == nil && me.identities.isEmpty)
  }

  @Test func identityRoundTrips() throws {
    let identity = try roundTrips(Identity.self, "identity")
    #expect(identity.kind == "passkey" && identity.lastUsedAt == nil)
  }

  @Test func addPasskeyRoundTrips() throws {
    let begun = try roundTrips(AddPasskeyBeginResponse.self, "addPasskeyBegin")
    #expect(begun.registration["publicKey"]?["excludeCredentials"]?.arrayValue?.count == 1)
    let finish = try roundTrips(AddPasskeyFinishRequest.self, "addPasskeyFinish")
    #expect(finish.ceremonyId == begun.ceremonyId)
  }

  @Test func enrollRoundTrips() throws {
    #expect(try roundTrips(EnrollRequest.self, "enrollRequest").platform == "ios")
    #expect(try roundTrips(EnrollResponse.self, "enrollResponse").user.username == "blove")
  }

  @Test func appleRoundTrips() throws {
    let begin = try roundTrips(AppleBeginRequest.self, "appleBeginRequest")
    #expect(begin.scheme == "b4app-local" && begin.verifierHash?.count == 64)
    let begun = try roundTrips(AppleBeginResponse.self, "appleBeginResponse")
    #expect(begun.ceremonyId == "5b0f1f3e-2d0c-4f6a-9a51-6c2d8e7f4b10")
    let native = try roundTrips(AppleNativeRequest.self, "appleNativeRequest")
    #expect(native.fullName == "Brian Love" && native.device.platform == "ios")
    let link = try roundTrips(AppleLinkNativeRequest.self, "appleLinkNativeRequest")
    #expect(link.ceremonyId == begun.ceremonyId)
    let handoff = try roundTrips(HandoffRequest.self, "handoffRequest")
    #expect(handoff.device.deviceId == "01a19a2b-bbc9-744f-9b64-011001ab330e")
  }

  // The native flow's begin body is empty, and an absent `fullName` is left out.
  @Test func appleTypesOmitWhatIsAbsent() throws {
    let empty = try JSONCoding.decoder.decode(
      JSONValue.self, from: JSONCoding.encoder.encode(AppleBeginRequest()))
    #expect(empty == [:])

    let native = AppleNativeRequest(
      ceremonyId: "c", identityToken: "jwt", authorizationCode: "code", fullName: nil,
      device: DeviceSpec(deviceName: "iPhone", platform: "ios"))
    let nativeJSON = try JSONCoding.decoder.decode(
      JSONValue.self, from: JSONCoding.encoder.encode(native))
    #expect(
      nativeJSON == [
        "ceremonyId": "c", "identityToken": "jwt", "authorizationCode": "code",
        "device": ["deviceName": "iPhone", "platform": "ios"],
      ])

    let handoff = HandoffRequest(
      handoff: "h", verifier: "v", device: DeviceSpec(deviceName: "Mac", platform: "macos"))
    let handoffJSON = try JSONCoding.decoder.decode(
      JSONValue.self, from: JSONCoding.encoder.encode(handoff))
    #expect(
      handoffJSON == [
        "handoff": "h", "verifier": "v", "device": ["deviceName": "Mac", "platform": "macos"],
      ])
  }

  @Test func secretsNeverReachADescription() throws {
    let session = try roundTrips(AuthSession.self, "authSession")
    let assertion = try roundTrips(PasskeyFinishRequest.self, "passkeyFinishAssertion")
    let add = try roundTrips(AddPasskeyFinishRequest.self, "addPasskeyFinish")
    let native = AppleNativeRequest(
      ceremonyId: "c", identityToken: "jwt-secret", authorizationCode: "code-secret", fullName: nil,
      device: DeviceSpec(deviceName: "iPhone", platform: "ios"))
    let handoff = HandoffRequest(
      handoff: "handoff-secret", verifier: "verifier-secret",
      device: DeviceSpec(deviceName: "Mac", platform: "macos"))
    let link = AppleLinkNativeRequest(
      ceremonyId: "c", identityToken: "jwt-secret", authorizationCode: "code-secret")
    let renderings: [String] = [
      "\(link)", String(reflecting: link),
      "\(session)", String(reflecting: session), "\(assertion)", String(reflecting: assertion),
      "\(add)", String(reflecting: add), "\(native)", String(reflecting: native), "\(handoff)",
      String(reflecting: handoff),
      "\(EnrollResponse(deviceId: "d", token: "enroll-secret", org: OrgInfo(slug: "o", name: "O"), user: UserInfo(username: "u", displayName: "U")))",
    ]
    for text in renderings {
      for secret in [
        session.token, "jwt-secret", "code-secret", "handoff-secret", "verifier-secret", "enroll-secret",
        "MEQCIGklL9n40zPU8qpmqh87qoiM38rhhWZcTMTtaPB", "o2NmbXRkbm9uZWdhdHRTdG10oGhh",
      ] {
        #expect(!text.contains(secret), "\(text) leaks \(secret)")
      }
    }
  }

  @Test func errorCodesCoverTheSignInRefusals() {
    let names = [
      "signup_closed", "ceremony_expired", "credential_rejected", "last_identity", "merge_refused",
      "shared_org", "signed_out", "work_running", "rate_limited",
    ]
    for name in names {
      #expect(ErrorCode(rawValue: name) != nil, "ErrorCode has no \(name)")
    }
  }
}
