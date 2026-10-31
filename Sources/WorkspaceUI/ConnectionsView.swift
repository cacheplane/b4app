import SwiftUI
import WorkspaceProtocol

struct ConnectionsView: View {
  @Bindable var model: WorkspaceModel

  private struct KindInfo {
    let kind: ConnectionKind
    let title: String
    let summary: String
    let milestone: String
    let runtime: RuntimeKind?
  }

  private let kinds = [
    KindInfo(
      kind: .codex, title: "Codex",
      summary:
        "Uses the installed Codex CLI and its official ChatGPT sign-in. No passwords are collected here.",
      milestone: "M1", runtime: .codex),
    KindInfo(
      kind: .claude, title: "Claude Code",
      summary:
        "Uses the installed Claude Code executable and its Claude plan sign-in. Plan allowances apply.",
      milestone: "M2", runtime: .claude),
    KindInfo(
      kind: .b4, title: "B4 agent",
      summary:
        "Attach a running B4 server (local HTTP on loopback, or a remote HTTPS endpoint) at one exact agent route. To run a local project from here, register it under Local servers and connect one of its routes.",
      milestone: "M3", runtime: nil),
  ]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        if let error = model.diagnosticsError {
          Text(error).foregroundStyle(.red)
        }
        Text("Configured").font(.headline)
        if model.connections.isEmpty {
          Text("No connections configured.").foregroundStyle(.secondary)
        } else {
          ForEach(model.connections) { connection in
            GroupBox {
              VStack(alignment: .leading, spacing: 6) {
                HStack {
                  Text(connection.label).bold()
                  Text(connection.kind.rawValue).foregroundStyle(.secondary)
                  Spacer()
                  StatusBadge(status: connection.status)
                }
                Text(connection.target.isEmpty ? "(executable not found)" : connection.target)
                  .font(.caption.monospaced()).foregroundStyle(.secondary)
                if let route = connection.routeKey {
                  Text(
                    "route \(route) · \(connection.b4Mode?.rawValue.replacingOccurrences(of: "_", with: " ") ?? "b4")"
                  )
                  .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                  Text("Auth: \(connection.authStatus.rawValue.replacingOccurrences(of: "_", with: " "))")
                    .font(.caption)
                  Spacer()
                  Button("Check") { Task { await model.inspectConnection(id: connection.id) } }
                    .disabled(model.busy)
                  if connection.kind != .b4, connection.authStatus != .authenticated {
                    Button(connection.kind == .codex ? "Sign in with ChatGPT" : "Sign in to Claude") {
                      Task { await model.login(connectionId: connection.id) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || connection.status == .error)
                    .accessibilityIdentifier("sign-in")
                  }
                }
              }
            }
          }
          if let error = model.lastError, model.surface == .connections {
            Text(error).font(.callout).foregroundStyle(.red)
          }
        }
        Text("Add connection").font(.headline)
        ForEach(kinds, id: \.kind) { info in
          GroupBox {
            VStack(alignment: .leading, spacing: 8) {
              Text(info.title).bold()
              Text(info.summary).foregroundStyle(.secondary)
              if let runtime = info.runtime {
                RuntimeStatusView(
                  runtime: model.diagnostics?.runtimes.first { $0.kind == runtime },
                  loading: model.diagnosticsLoading)
              }
              if info.kind != .b4 {
                Button("Add \(info.title) connection") { Task { await model.addConnection(kind: info.kind) } }
                  .buttonStyle(.borderedProminent)
                  .disabled(model.busy)
                  .accessibilityIdentifier("add-\(info.kind.rawValue)")
              } else {
                B4AttachForm(model: model)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .padding()
    }
    .navigationTitle("Connections")
    .toolbar {
      ToolbarItem {
        Button("Re-check runtimes") { Task { await model.refreshDiagnostics() } }
          .disabled(model.link != .ready || model.diagnosticsLoading)
      }
    }
    .task(id: model.link) {
      if model.link == .ready, model.diagnostics == nil { await model.refreshDiagnostics() }
    }
  }
}

/// Attach-endpoint form. It collects a credential *reference*, never a secret (spec 3.2, D-022).
struct B4AttachForm: View {
  @Bindable var model: WorkspaceModel
  @State private var url = "http://127.0.0.1:8000"
  @State private var route = "/chat#agent"
  @State private var label = ""
  @State private var reference = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("Base URL (https://host, or http://127.0.0.1:port)", text: $url).textFieldStyle(
        .roundedBorder)
      TextField("Route key, for example /chat#agent", text: $route).textFieldStyle(.roundedBorder)
      TextField("Label (optional)", text: $label).textFieldStyle(.roundedBorder)
      TextField("Credential reference (optional, secret:…)", text: $reference).textFieldStyle(.roundedBorder)
      Text(
        "Remote endpoints must use HTTPS. Create a secret with `agent-workspace credential add <label>` and paste only its reference here; it is sent as a bearer to this origin only. The check confirms the server is reachable, not that its model credentials work."
      )
      .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Button("Attach B4 endpoint") {
        Task {
          await model.addConnection(
            kind: .b4, label: label.isEmpty ? nil : label, url: url, route: route,
            authReference: reference.isEmpty ? nil : reference)
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(model.busy || url.isEmpty || route.isEmpty)
      .accessibilityIdentifier("add-b4")
    }
  }
}

struct RuntimeStatusView: View {
  let runtime: RuntimeDiagnostic?
  let loading: Bool

  var body: some View {
    if let runtime {
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
        GridRow {
          Text("Status").foregroundStyle(.secondary)
          StatusBadge(status: runtime.status)
        }
        GridRow {
          Text("Auth").foregroundStyle(.secondary)
          Text(runtime.authStatus.rawValue)
        }
        GridRow {
          Text("Version").foregroundStyle(.secondary)
          Text(runtime.version ?? "unknown")
        }
        GridRow {
          Text("Executable").foregroundStyle(.secondary)
          Text(runtime.executablePath ?? "not found").font(.caption.monospaced())
        }
        if let message = runtime.message {
          GridRow {
            Text("Note").foregroundStyle(.secondary)
            Text(message).fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .font(.callout)
    } else {
      Text(loading ? "Checking…" : "Not checked yet.").foregroundStyle(.secondary).font(.callout)
    }
  }
}

struct StatusBadge: View {
  let status: ConnectionStatus

  var body: some View {
    Text(status.rawValue)
      .font(.caption)
      .padding(.horizontal, 8)
      .padding(.vertical, 2)
      .background(color.opacity(0.15), in: Capsule())
      .foregroundStyle(color)
  }

  private var color: Color {
    switch status {
    case .ready: return .green
    case .error, .incompatible, .offline: return .red
    case .connecting, .unconfigured: return .orange
    }
  }
}
