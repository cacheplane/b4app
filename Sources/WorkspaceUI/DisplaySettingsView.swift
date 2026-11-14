import SwiftUI
import WorkspaceProtocol

/// Settings, Display (the Mac's): the Dense switch, which draws the threads that do not need the owner
/// as tight rows in the Mac's sidebar. It is the account's stored density, written for every device;
/// the phone keeps its rows at either density.
struct DisplaySettingsView: View {
  @Bindable var model: WorkspaceModel

  static let denseLabel = "Dense"
  static let denseDescription = "Tighter rows for the threads that don\u{2019}t need you."

  init(model: WorkspaceModel) {
    self.model = model
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: LLA.Space.xl) {
        LLAFormGroup {
          // The label and the description are the switch's own label, so VoiceOver reads them as one.
          Toggle(isOn: dense) {
            VStack(alignment: .leading, spacing: LLA.Space.xs) {
              Text(Self.denseLabel).font(LLAFont.body).foregroundStyle(LLA.Color.ink)
              Text(Self.denseDescription).llaSmallMuted().fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .toggleStyle(.switch)
          .accessibilityIdentifier("display-dense")
          .padding(.horizontal, LLA.Space.m)
          .padding(.vertical, LLA.Space.s)
          .frame(minHeight: 48)
        }
      }
      .padding(LLA.Metrics.margin)
      .frame(maxWidth: 820, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(LLA.Color.bg)
    .navigationTitle(SettingsPage.display.title)
  }

  private var dense: Binding<Bool> {
    Binding(
      get: { model.viewSettings.density == .dense },
      set: { value in Task { await model.setDensity(value ? .dense : .normal) } })
  }
}
