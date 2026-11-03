import Foundation

/// Which APNs endpoint the phone's token belongs to, decided from the build (M8f APNs design, "The
/// phone"). Pure: the app passes whether it is a Simulator build and the bytes of its
/// `embedded.mobileprovision`, if any.
public enum PushEnvironment {
  public static let sandbox = "sandbox"
  public static let production = "production"

  /// The Simulator is `sandbox`. On a device, an embedded profile (development and ad hoc builds)
  /// names its `aps-environment`: `development` is `sandbox`, `production` is `production`. A device
  /// with no profile (TestFlight and App Store builds, whose profile Apple strips), or one whose
  /// entitlement cannot be read, is `production`.
  public static func resolve(isSimulator: Bool, profile: Data?) -> String {
    if isSimulator { return sandbox }
    guard let profile, let environment = apsEnvironment(inProfile: profile) else { return production }
    return environment == "development" ? sandbox : production
  }

  /// The profile is a CMS envelope around an XML property list; the plist sits in the clear between
  /// `<?xml` and `</plist>`, so it is found by those markers rather than by verifying the signature.
  static func apsEnvironment(inProfile profile: Data) -> String? {
    guard let start = profile.range(of: Data("<?xml".utf8)),
      let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex)
    else { return nil }
    let plist = profile.subdata(in: start.lowerBound..<end.upperBound)
    guard
      let root = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil)
        as? [String: Any],
      let entitlements = root["Entitlements"] as? [String: Any]
    else { return nil }
    return entitlements["aps-environment"] as? String
  }
}
