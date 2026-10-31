import SwiftUI
import WorkspaceProtocol

struct DiagnosticsView: View {
  @Bindable var model: WorkspaceModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        if let error = model.diagnosticsError { Text(error).foregroundStyle(.red) }
        if let report = model.diagnostics {
          Text("Coordinator").font(.headline)
          Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            row("Version", "\(report.coordinator.version) (pid \(report.coordinator.pid))")
            row("Started", report.coordinator.startedAt)
            row("Epoch", "\(report.coordinator.epoch) @ \(report.coordinator.sequence)", mono: true)
            row("Socket", report.coordinator.socketPath, mono: true)
            row("Database", report.coordinator.databasePath, mono: true)
            row("Host", "\(report.host.platform) \(report.host.arch) (\(report.host.release))")
          }
          .font(.callout)
          Text("Runtimes").font(.headline)
          ForEach(Array(report.runtimes.enumerated()), id: \.offset) { _, runtime in
            GroupBox {
              VStack(alignment: .leading, spacing: 6) {
                HStack {
                  Text(runtime.kind.rawValue).bold()
                  StatusBadge(status: runtime.status)
                  Text("auth: \(runtime.authStatus.rawValue)").foregroundStyle(.secondary)
                  Spacer()
                  Text(runtime.version ?? "-").foregroundStyle(.secondary)
                }
                Text(runtime.executablePath ?? "not found").font(.caption.monospaced()).foregroundStyle(
                  .secondary)
                if let message = runtime.message {
                  Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          Text("Recent errors").font(.headline)
          if report.recentErrors.isEmpty {
            Text("None.").foregroundStyle(.secondary)
          } else {
            ForEach(Array(report.recentErrors.enumerated()), id: \.offset) { _, error in
              Text("\(error.at) \(error.scope) \(error.code): \(error.message)").font(.caption.monospaced())
            }
          }
        } else {
          Text(model.link == .ready ? "Loading…" : "Waiting for the coordinator.").foregroundStyle(.secondary)
        }
      }
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
    }
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
      Text(label).foregroundStyle(.secondary)
      Text(value).font(mono ? .callout.monospaced() : .callout).textSelection(.enabled)
    }
  }
}

struct LocalServersView: View {
  var body: some View {
    ContentUnavailableView {
      Label("Local servers", systemImage: "server.rack")
    } description: {
      Text(
        "Managed B4 servers (start, stop, restart, routes, redacted logs) arrive in M4. Attached servers are never stopped from here."
      )
    }
    .navigationTitle("Local servers")
  }
}
