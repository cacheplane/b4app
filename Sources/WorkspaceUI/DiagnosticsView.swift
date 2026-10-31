import SwiftUI
import WorkspaceProtocol

struct DiagnosticsView: View {
  @Bindable var model: WorkspaceModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: LLA.Space.xl) {
        if let error = model.diagnosticsError {
          Text(error).font(LLAFont.small).foregroundStyle(LLA.Color.danger)
        }
        if let report = model.diagnostics {
          LLASectionHead("Coordinator")
          Grid(alignment: .leading, horizontalSpacing: LLA.Space.l, verticalSpacing: LLA.Space.xs) {
            row("Version", "\(report.coordinator.version) (pid \(report.coordinator.pid))")
            row("Started", report.coordinator.startedAt)
            row("Epoch", "\(report.coordinator.epoch) @ \(report.coordinator.sequence)", mono: true)
            row("Socket", report.coordinator.socketPath, mono: true)
            row("Database", report.coordinator.databasePath, mono: true)
            row("Host", "\(report.host.platform) \(report.host.arch) (\(report.host.release))")
          }
          LLASectionHead("Runtimes").padding(.top, LLA.Space.l)
          ForEach(Array(report.runtimes.enumerated()), id: \.offset) { _, runtime in
            LLACard {
              VStack(alignment: .leading, spacing: LLA.Space.s) {
                HStack(spacing: LLA.Space.s) {
                  Text(runtime.kind.rawValue).font(LLAFont.bodyStrong).foregroundStyle(LLA.Color.ink)
                  StatusBadge(status: runtime.status)
                  Text("signed in: \(runtime.authStatus.rawValue.replacingOccurrences(of: "_", with: " "))")
                    .llaSmallMuted()
                  Spacer()
                  Text(runtime.version ?? "-").llaSmallMuted()
                }
                Text(runtime.executablePath ?? "not found").llaCodeMuted()
                if let message = runtime.message {
                  Text(message).llaSmall().fixedSize(horizontal: false, vertical: true)
                }
              }
            }
          }
          LLASectionHead("Recent errors").padding(.top, LLA.Space.l)
          if report.recentErrors.isEmpty {
            Text("None.").llaMuted()
          } else {
            VStack(alignment: .leading, spacing: 0) {
              ForEach(Array(report.recentErrors.enumerated()), id: \.offset) { index, error in
                if index > 0 { Hairline() }
                Text("\(error.at) \(error.scope) \(error.code): \(error.message)").llaCodeMuted()
                  .textSelection(.enabled)
                  .padding(.vertical, LLA.Space.s)
              }
            }
          }
        } else {
          Text(model.link == .ready ? "Loading…" : "Waiting for the coordinator.").llaMuted()
        }
      }
      .padding(LLA.Space.xl)
      .frame(maxWidth: 820, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(LLA.Color.bg)
    .navigationTitle("Diagnostics")
    .toolbar {
      ToolbarItem {
        Button("Refresh") { Task { await model.refreshDiagnostics() } }
          .disabled(model.link != .ready || model.diagnosticsLoading)
      }
    }
    .task(id: model.link) {
      if model.link == .ready, model.diagnostics == nil { await model.refreshDiagnostics() }
    }
  }

  @ViewBuilder private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
    GridRow {
      Text(label).llaSmallMuted()
      Group {
        if mono { Text(value).llaCodeMuted().foregroundStyle(LLA.Color.ink) } else { Text(value).llaSmall() }
      }
      .textSelection(.enabled)
    }
  }
}
