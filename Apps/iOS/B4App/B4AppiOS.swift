import SwiftUI
import WorkspaceClient
import WorkspaceUI

/// The iOS companion reads the workspace the Mac syncs to the hub (M8a): until this device has
/// joined it shows the Connect screen, then the shared shell over the local mirror. Writing from the
/// phone arrives in M8b and sending turns through the hub in M8c; the mirror refuses both.
@main
struct B4AppiOS: App {
  @State private var host = MirrorHost.shared
  @State private var model = WorkspaceModel(transportProvider: MirrorHost.transportProvider)

  var body: some Scene {
    WindowGroup {
      if host.isLinked {
        WorkspaceRootView(model: model)
      } else {
        HubConnectView(host: host)
      }
    }
  }
}
