import Foundation
import Testing

@testable import WorkspacePlatform

@Suite struct FlavorTests {
  /// A scratch `X.app` whose Info.plist optionally names a flavour, with a helper executable path
  /// at `Contents/Helpers/agent-workspace` (the file need not exist).
  private func makeApp(flavor: String?) throws -> (root: URL, executable: URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("flavor-\(UUID().uuidString)", isDirectory: true)
    let contents = root.appendingPathComponent("X.app/Contents", isDirectory: true)
    try FileManager.default.createDirectory(
      at: contents.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
    var plist: [String: Any] = ["CFBundleIdentifier": "com.example.x"]
    if let flavor { plist["B4AppFlavor"] = flavor }
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: contents.appendingPathComponent("Info.plist"))
    return (root, contents.appendingPathComponent("Helpers/agent-workspace"))
  }

  @Test func resolvesFromEnvironmentFirst() throws {
    let app = try makeApp(flavor: "prod")
    defer { try? FileManager.default.removeItem(at: app.root) }
    #expect(Flavor.resolve(environment: ["B4APP_FLAVOR": "beta"], executableURL: app.executable) == .beta)
  }

  @Test func resolvesFromEnclosingApp() throws {
    let app = try makeApp(flavor: "prod")
    defer { try? FileManager.default.removeItem(at: app.root) }
    #expect(Flavor.resolve(environment: [:], executableURL: app.executable) == .prod)
  }

  @Test func anUnknownEnvironmentValueFallsThroughToTheBundle() throws {
    let app = try makeApp(flavor: "beta")
    defer { try? FileManager.default.removeItem(at: app.root) }
    #expect(Flavor.resolve(environment: ["B4APP_FLAVOR": "staging"], executableURL: app.executable) == .beta)
  }

  @Test func anUnknownBundleValueFallsThroughToLocal() throws {
    let app = try makeApp(flavor: "nightly")
    defer { try? FileManager.default.removeItem(at: app.root) }
    #expect(Flavor.resolve(environment: [:], executableURL: app.executable) == .local)
  }

  @Test func defaultsToLocal() throws {
    let app = try makeApp(flavor: nil)
    defer { try? FileManager.default.removeItem(at: app.root) }
    #expect(Flavor.resolve(environment: [:], executableURL: app.executable) == .local)
    #expect(Flavor.resolve(environment: [:], executableURL: nil) == .local)
    #expect(
      Flavor.resolve(environment: [:], executableURL: URL(fileURLWithPath: "/usr/bin/true")) == .local)
  }

  @Test func resolutionSaysWhereTheFlavourCameFrom() throws {
    let local = try makeApp(flavor: "local")
    let bare = try makeApp(flavor: nil)
    defer {
      try? FileManager.default.removeItem(at: local.root)
      try? FileManager.default.removeItem(at: bare.root)
    }
    func resolve(_ env: [String: String], _ url: URL?) -> Flavor.Resolution {
      Flavor.resolution(environment: env, executableURL: url)
    }
    #expect(
      resolve(["B4APP_FLAVOR": "local"], bare.executable)
        == Flavor.Resolution(flavor: .local, source: .environment))
    #expect(resolve([:], local.executable) == Flavor.Resolution(flavor: .local, source: .bundle))
    // The fallback is never explicit: no variable, no flavour in the bundle, an unknown value.
    #expect(resolve([:], bare.executable) == Flavor.Resolution(flavor: .local, source: .default))
    #expect(resolve([:], nil) == Flavor.Resolution(flavor: .local, source: .default))
    #expect(resolve(["B4APP_FLAVOR": "staging"], nil) == Flavor.Resolution(flavor: .local, source: .default))
    #expect(
      resolve(["B4APP_FLAVOR": "staging"], local.executable)
        == Flavor.Resolution(flavor: .local, source: .bundle))
  }

  @Test func rawValuesAreTheEnvironmentSpellings() {
    #expect(Flavor.allCases.map(\.rawValue) == ["prod", "beta", "local"])
  }

  @Test func tableValues() {
    struct Row {
      var flavor: Flavor
      var hubURL: String
      var siteDomain: String
      var appleSignIn: Bool
      var dirSuffix: String
      var idSuffix: String
      var urlScheme: String
      var badge: String?
      var macBundleId: String
      var keychainGroupSuffix: String
    }
    let rows = [
      Row(
        flavor: .prod, hubURL: "https://hub.b4.run", siteDomain: "b4.run", appleSignIn: true,
        dirSuffix: "", idSuffix: "", urlScheme: "b4app", badge: nil,
        macBundleId: "com.cacheplane.b4app", keychainGroupSuffix: ""),
      Row(
        flavor: .beta, hubURL: "https://hub.test.b4.run", siteDomain: "test.b4.run", appleSignIn: true,
        dirSuffix: "-beta", idSuffix: ".beta", urlScheme: "b4app-beta", badge: "Test hub",
        macBundleId: "com.cacheplane.b4app.beta", keychainGroupSuffix: ".beta"),
      Row(
        flavor: .local, hubURL: "http://localhost:8080", siteDomain: "local.b4.run", appleSignIn: false,
        dirSuffix: "-local", idSuffix: ".local", urlScheme: "b4app-local", badge: "Local hub",
        macBundleId: "com.cacheplane.b4app.local", keychainGroupSuffix: ".local"),
    ]
    #expect(Set(rows.map(\.flavor)) == Set(Flavor.allCases))
    for row in rows {
      let flavor = row.flavor
      #expect(flavor.hubURL.absoluteString == row.hubURL)
      #expect(flavor.siteDomain == row.siteDomain)
      #expect(flavor.appleSignIn == row.appleSignIn)
      #expect(flavor.dirSuffix == row.dirSuffix)
      #expect(flavor.idSuffix == row.idSuffix)
      #expect(flavor.urlScheme == row.urlScheme)
      #expect(flavor.badge == row.badge)
      #expect(flavor.macBundleId == row.macBundleId)
      #expect(flavor.keychainGroupSuffix == row.keychainGroupSuffix)
    }
  }

  @Test func dataDirectoryPerFlavour() {
    #expect(PlatformPaths.directoryName(for: .prod) == "b4app")
    #expect(PlatformPaths.directoryName(for: .beta) == "b4app-beta")
    #expect(PlatformPaths.directoryName(for: .local) == "b4app-local")
    for flavor in Flavor.allCases {
      let paths = PlatformPaths.resolve(environment: ["B4APP_FLAVOR": flavor.rawValue, "TMPDIR": "/tmp/"])
      #expect(paths.dataDir.hasSuffix("/" + PlatformPaths.directoryName(for: flavor)))
      #expect(paths.runtimeDir == "/tmp/" + PlatformPaths.directoryName(for: flavor))
    }
    let local = PlatformPaths.resolve(environment: ["B4APP_FLAVOR": "local"])
    #expect(local.dataDir.hasSuffix("b4app-local"))
  }
}
