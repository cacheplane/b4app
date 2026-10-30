import SwiftUI
import WorkspaceClient
import WorkspaceUI

/// The iOS companion renders the same shell. It cannot run a coordinator or reach the Mac's socket;
/// a secure relay is designed later (spec section 15), so the transport reports unavailable.
@main
struct B4AppiOS: App {
  @State private var model = WorkspaceModel(transportProvider: {
    UnavailableTransport(
      reason: "iOS cannot reach the Mac coordinator yet. A secure relay is a follow-on milestone.")
  })

  var body: some Scene {
    WindowGroup {
      WorkspaceRootView(model: model)
    }
  }
}
