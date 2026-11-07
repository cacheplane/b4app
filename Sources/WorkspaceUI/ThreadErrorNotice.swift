import SwiftUI
import WorkspaceProtocol

/// One explanation followed by an aligned action row. Native diagnostics stay available without
/// competing with the recovery instructions for space.
struct ThreadErrorNotice: View {
  let error: String
  let failure: WorkspaceError?
  let remedy: Remediation?
  let perform: (Remediation.Action) -> Void
  let dismiss: () -> Void
  @State var detailsExpanded = false

  private var message: String { remedy?.message ?? failure?.message ?? error }

  var body: some View {
    LLACard(fill: .surface, padding: LLA.Space.m) {
      VStack(alignment: .leading, spacing: LLA.Space.m) {
        Text(message)
          .font(LLAFont.small)
          .foregroundStyle(LLA.Color.danger)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          // Reserve the instructions' wrapped height before flexible diagnostics take space.
          .layoutPriority(1)
        if let failure {
          DisclosureGroup("Details", isExpanded: $detailsExpanded) {
            // A split view also measures us at zero width. Keep wrapped, selectable diagnostics
            // inside a bounded scroll region so expansion cannot become the window's minimum size.
            ScrollView {
              VStack(alignment: .leading, spacing: LLA.Space.xs) {
                Text(failure.code.rawValue).llaCodeMuted()
                if let native = failure.details?["nativeMessage"]?.stringValue
                  ?? failure.details?["cause"]?["nativeMessage"]?.stringValue
                {
                  Text(native).llaSmallMuted()
                } else if failure.message != message {
                  Text(failure.message).llaSmallMuted()
                }
              }
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: LLA.Metrics.control, maxHeight: LLA.Metrics.diagnosticsMaxHeight)
          }
          .font(LLAFont.small)
          .foregroundStyle(LLA.Color.muted)
        }
        RecoveryNoticeActions {
          if let remedy, let title = remedy.actionTitle, remedy.action != .none {
            Button(title) { perform(remedy.action) }
              .buttonStyle(.llaSecondary)
              .accessibilityIdentifier("remediation")
          }
          Button("Dismiss", action: dismiss).buttonStyle(.llaSecondary)
        }
      }
    }
    .accessibilityIdentifier("error-banner")
  }
}

/// Keep controls on one row when they fit, and stack them at narrow widths or large text sizes.
struct RecoveryNoticeActions<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: LLA.Space.s) { content() }.fixedSize(horizontal: true, vertical: false)
      VStack(alignment: .leading, spacing: LLA.Space.s) { content() }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
