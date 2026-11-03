import SwiftUI
import WidgetKit
import WorkspaceUI

/// The widget extension (M8f): one widget, the threads that need the owner.
@main
struct AttentionWidgetBundle: WidgetBundle {
  init() {
    LLAFonts.register()
  }

  var body: some Widget {
    AttentionWidget()
  }
}
