import Foundation
import WorkspaceProtocol

// The sign-in and account routes of `Hub/API.md`, as the hub's Rust types send and read them
// (`routes/auth.rs`, `routes/me.rs`, `routes/enroll.rs`). `Tests/Fixtures/sync/auth.json` holds one
// example of each, and the hub's `auth_fixture` test and this module's `AuthWireTests` both read it.
//
// The WebAuthn options and responses are opaque `JSONValue`s: the client hands them to the platform
// and back without reading them. Anything that carries a secret (a token, a WebAuthn response, an
// Apple identity token, a handoff's verifier) prints as `<redacted>` in a description, so it cannot
// reach a log through string interpolation.

/// `GET /v1/auth/config`: what this hub offers, so a client hides the rest.
public struct AuthConfig: Codable, Sendable, Equatable {
  public struct Passkeys: Codable, Sendable, Equatable {
    public var rpId: String
    public init(rpId: String) { self.rpId = rpId }
  }

  public struct Apple: Codable, Sendable, Equatable {
    public var native: Bool
    public var web: Bool
    public init(native: Bool, web: Bool) {
      self.native = native
      self.web = web
    }
  }

  public enum Signup: String, Codable, Sendable, Equatable {
    case open
    case closed
  }

  public var passkeys: Passkeys
  public var apple: Apple
  public var signup: Signup

  public init(passkeys: Passkeys, apple: Apple, signup: Signup) {
    self.passkeys = passkeys
    self.apple = apple
    self.signup = signup
  }
}

/// The device a sign-in is for. `deviceId`, when it names an unrevoked device of the signing-in user
/// on the same platform, is reused (and renamed); otherwise the hub makes a new one.
public struct DeviceSpec: Codable, Sendable, Equatable {
  public var deviceName: String
  /// `macos`, `ios`, or `cli`.
  public var platform: String
  public var deviceId: String?

  public init(deviceName: String, platform: String, deviceId: String? = nil) {
    self.deviceName = deviceName
    self.platform = platform
    self.deviceId = deviceId
  }
}

/// `POST /v1/auth/passkey/begin`'s answer. `registration` is absent while sign-up is closed.
public struct PasskeyBeginResponse: Codable, Sendable, Equatable {
  public var ceremonyId: String
  /// A WebAuthn `PublicKeyCredentialRequestOptions` wrapper (`{"publicKey": {...}}`).
  public var authentication: JSONValue
  /// A `PublicKeyCredentialCreationOptions` wrapper for a new user.
  public var registration: JSONValue?

  public init(ceremonyId: String, authentication: JSONValue, registration: JSONValue? = nil) {
    self.ceremonyId = ceremonyId
    self.authentication = authentication
    self.registration = registration
  }
}

/// `POST /v1/auth/passkey/finish`'s body: exactly one of `assertion` (sign in) or `attestation`
/// (sign up), each the authenticator's response as the platform produced it.
public struct PasskeyFinishRequest: Codable, Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public var ceremonyId: String
  public var assertion: JSONValue?
  public var attestation: JSONValue?
  public var device: DeviceSpec

  public init(ceremonyId: String, assertion: JSONValue?, attestation: JSONValue?, device: DeviceSpec) {
    self.ceremonyId = ceremonyId
    self.assertion = assertion
    self.attestation = attestation
    self.device = device
  }

  public var description: String {
    "PasskeyFinishRequest(ceremonyId: \(ceremonyId), response: <redacted>, device: \(device.deviceName))"
  }
  public var debugDescription: String { description }
}

/// What every route that signs a device in answers: the enrollment shape plus whether the user still
/// has to onboard. The token is in this answer and nowhere else.
public struct AuthSession: Codable, Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public var deviceId: String
  public var token: String
  public var org: OrgInfo
  public var user: UserInfo
  public var needsOnboarding: Bool

  public init(deviceId: String, token: String, org: OrgInfo, user: UserInfo, needsOnboarding: Bool) {
    self.deviceId = deviceId
    self.token = token
    self.org = org
    self.user = user
    self.needsOnboarding = needsOnboarding
  }

  public var description: String {
    "AuthSession(deviceId: \(deviceId), token: <redacted>, org: \(org.slug), user: \(user.username), "
      + "needsOnboarding: \(needsOnboarding))"
  }
  public var debugDescription: String { description }
}

/// `PUT /v1/me/profile`'s body.
public struct ProfileRequest: Codable, Sendable, Equatable {
  public var fullName: String
  public init(fullName: String) { self.fullName = fullName }
}

/// One of an account's sign-in methods, in `GET /v1/me`'s `identities`. No credential id, stored
/// passkey, Apple `sub`, or refresh token is ever part of it.
public struct Identity: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  /// `passkey` or `apple`.
  public var kind: String
  /// A passkey's name, or an Apple ID's (often relay) email.
  public var name: String?
  /// RFC 3339 in UTC with microseconds, exactly as the hub sent it.
  public var createdAt: String
  /// `nil` for one never used to sign in.
  public var lastUsedAt: String?

  public init(id: String, kind: String, name: String? = nil, createdAt: String, lastUsedAt: String? = nil) {
    self.id = id
    self.kind = kind
    self.name = name
    self.createdAt = createdAt
    self.lastUsedAt = lastUsedAt
  }

  private enum CodingKeys: String, CodingKey { case id, kind, name, createdAt, lastUsedAt }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    kind = try container.decode(String.self, forKey: .kind)
    name = try container.decodeIfPresent(String.self, forKey: .name)
    createdAt = try container.decode(String.self, forKey: .createdAt)
    lastUsedAt = try container.decodeIfPresent(String.self, forKey: .lastUsedAt)
  }

  /// The hub always sends `name` and `lastUsedAt`, as `null` when unset; so does this.
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(kind, forKey: .kind)
    try container.encode(name, forKey: .name)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(lastUsedAt, forKey: .lastUsedAt)
  }
}

/// `POST /v1/me/passkeys/begin`'s answer: registration options for another passkey of the signed-in
/// user, excluding the ones they have.
public struct AddPasskeyBeginResponse: Codable, Sendable, Equatable {
  public var ceremonyId: String
  public var registration: JSONValue

  public init(ceremonyId: String, registration: JSONValue) {
    self.ceremonyId = ceremonyId
    self.registration = registration
  }
}

/// `POST /v1/me/passkeys/finish`'s body.
public struct AddPasskeyFinishRequest: Codable, Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public var ceremonyId: String
  public var attestation: JSONValue

  public init(ceremonyId: String, attestation: JSONValue) {
    self.ceremonyId = ceremonyId
    self.attestation = attestation
  }

  public var description: String {
    "AddPasskeyFinishRequest(ceremonyId: \(ceremonyId), attestation: <redacted>)"
  }
  public var debugDescription: String { description }
}

// MARK: - Sign in with Apple
//
// The hub serves these routes from its Task 13; the shapes follow the design's route table and have no
// fixture example until the hub does.

/// `POST /v1/auth/apple/begin`'s answer. The native flow passes the SHA-256 of `nonce` to Apple.
public struct AppleBeginResponse: Codable, Sendable, Equatable {
  public var ceremonyId: String
  public var nonce: String

  public init(ceremonyId: String, nonce: String) {
    self.ceremonyId = ceremonyId
    self.nonce = nonce
  }
}

/// `POST /v1/auth/apple/native`'s body. `fullName` is what Apple returns, on the first sign-in only.
public struct AppleNativeRequest: Codable, Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public var ceremonyId: String
  public var identityToken: String
  public var authorizationCode: String
  public var fullName: String?
  public var device: DeviceSpec

  public init(
    ceremonyId: String, identityToken: String, authorizationCode: String, fullName: String?,
    device: DeviceSpec
  ) {
    self.ceremonyId = ceremonyId
    self.identityToken = identityToken
    self.authorizationCode = authorizationCode
    self.fullName = fullName
    self.device = device
  }

  public var description: String {
    "AppleNativeRequest(ceremonyId: \(ceremonyId), identityToken: <redacted>, "
      + "authorizationCode: <redacted>, device: \(device.deviceName))"
  }
  public var debugDescription: String { description }
}

/// `POST /v1/auth/handoff`'s body: the one-time code the web flow's redirect carried, with the
/// verifier that proves this app began the ceremony.
public struct HandoffRequest: Codable, Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public var handoff: String
  public var verifier: String
  public var device: DeviceSpec

  public init(handoff: String, verifier: String, device: DeviceSpec) {
    self.handoff = handoff
    self.verifier = verifier
    self.device = device
  }

  public var description: String {
    "HandoffRequest(handoff: <redacted>, verifier: <redacted>, device: \(device.deviceName))"
  }
  public var debugDescription: String { description }
}
