import Foundation
import Testing

@testable import WorkspaceMirror

/// A provisioning profile as the app finds it: a CMS envelope (binary) around an XML property list.
private func profile(
  entitlements: String, prefix: [UInt8] = [0x30, 0x82, 0x0A, 0xFF, 0x06, 0x09, 0x00]
) -> Data {
  let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>Name</key><string>iOS Team Provisioning Profile</string>
    <key>Entitlements</key><dict>\(entitlements)</dict>
    </dict></plist>
    """
  return Data(prefix) + Data(plist.utf8) + Data([0xA0, 0x80, 0x00, 0x00, 0xFF])
}

struct PushEnvironmentTests {
  @Test func deviceWithoutProfileIsProduction() {
    #expect(PushEnvironment.resolve(isSimulator: false, profile: nil) == "production")
  }

  @Test func developmentProfileIsSandbox() {
    let data = profile(entitlements: "<key>aps-environment</key><string>development</string>")
    #expect(PushEnvironment.resolve(isSimulator: false, profile: data) == "sandbox")
  }

  @Test func productionProfileIsProduction() {
    let data = profile(entitlements: "<key>aps-environment</key><string>production</string>")
    #expect(PushEnvironment.resolve(isSimulator: false, profile: data) == "production")
  }

  @Test func simulatorIsSandbox() {
    #expect(PushEnvironment.resolve(isSimulator: true, profile: nil) == "sandbox")
    let production = profile(entitlements: "<key>aps-environment</key><string>production</string>")
    #expect(PushEnvironment.resolve(isSimulator: true, profile: production) == "sandbox")
  }

  @Test func garbledProfileIsProduction() {
    let noEntitlement = profile(entitlements: "<key>get-task-allow</key><true/>")
    #expect(PushEnvironment.resolve(isSimulator: false, profile: noEntitlement) == "production")
    let noPlist = Data([0x30, 0x82, 0x01, 0x02, 0x03])
    #expect(PushEnvironment.resolve(isSimulator: false, profile: noPlist) == "production")
    #expect(PushEnvironment.resolve(isSimulator: false, profile: Data()) == "production")
    let truncated = Data("<?xml version=\"1.0\"?><plist><dict><key>Entitlements</key>".utf8)
    #expect(PushEnvironment.resolve(isSimulator: false, profile: truncated) == "production")
    let broken = Data("<?xml version=\"1.0\"?><plist><dict><key>x</string></plist>".utf8)
    #expect(PushEnvironment.resolve(isSimulator: false, profile: broken) == "production")
    let wrongType = profile(entitlements: "<key>aps-environment</key><integer>1</integer>")
    #expect(PushEnvironment.resolve(isSimulator: false, profile: wrongType) == "production")
  }
}
