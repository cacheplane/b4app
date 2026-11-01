import Testing
import WorkspaceSync

@Suite struct DevicePresenceTests {
  private let liveMac = DeviceInfo(id: "m1", name: "Mac", platform: "macos")
  private let revokedMac = DeviceInfo(
    id: "m0", name: "Old Mac", platform: "macos", revokedAt: "2026-11-01T10:00:00Z")
  private let phone = DeviceInfo(id: "p1", name: "iPhone", platform: "ios")

  @Test func emptyDeviceListIsNotDisconnected() {
    // Before the first `GET /v1/devices` the mirror's table is empty; that is not a lost host.
    #expect([DeviceInfo]().hostDisconnected == false)
  }

  @Test func onlyRevokedMacsIsDisconnected() {
    #expect([revokedMac].hostDisconnected)
  }

  @Test func phonesDoNotCount() {
    #expect([phone, revokedMac].hostDisconnected)
  }

  @Test func oneLiveMacOfTwoIsConnected() {
    #expect([revokedMac, liveMac, phone].hostDisconnected == false)
  }
}
