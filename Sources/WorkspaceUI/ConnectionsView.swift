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
      VStack(alignment: .leading, spacing: LLA.Space.xl) {
        if let error = model.diagnosticsError {
          Text(error).font(LLAFont.small).foregroundStyle(LLA.Color.danger)
        }
        LLASectionHead(
          "Configured",
          intro: "Each connection is one runtime and one identity. Threads never move between them.")
        if model.connections.isEmpty {
          Text("No connections configured.").llaMuted()
        } else {
          ForEach(model.connections) { connection in
            ConnectionCard(model: model, connection: connection)
          }
          if let error = model.lastError, model.settingsVisible, model.settingsPage == .connections {
            Text(error).font(LLAFont.small).foregroundStyle(LLA.Color.danger)
          }
        }
        LLASectionHead("Add a connection").padding(.top, LLA.Space.l)
        ForEach(kinds, id: \.kind) { info in
          LLACard {
            VStack(alignment: .leading, spacing: LLA.Space.s) {
              Text(info.title).font(LLAFont.bodyStrong).foregroundStyle(LLA.Color.ink)
              Text(info.summary).llaSmallMuted().fixedSize(horizontal: false, vertical: true)
              if let runtime = info.runtime {
                RuntimeStatusView(
                  runtime: model.diagnostics?.runtimes.first { $0.kind == runtime },
                  loading: model.diagnosticsLoading)
              }
              if info.kind != .b4 {
                Button("Add \(info.title) connection") { Task { await model.addConnection(kind: info.kind) } }
                  .buttonStyle(.llaPrimary)
                  .disabled(model.busy)
                  .padding(.top, LLA.Space.xs)
                  .accessibilityIdentifier("add-\(info.kind.rawValue)")
              } else {
                B4AttachForm(model: model)
              }
            }
          }
        }
      }
      .padding(LLA.Space.xl)
      .frame(maxWidth: 820, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(LLA.Color.bg)
    .navigationTitle("Connections")
    .modifier(
      SettingsPageAction(
        title: "Re-check runtimes", disabled: model.link != .ready || model.diagnosticsLoading
      ) { Task { await model.refreshDiagnostics() } }
    )
    .task(id: model.link) {
      if model.link == .ready, model.diagnostics == nil { await model.refreshDiagnostics() }
    }
  }
}

struct ConnectionCard: View {
  @Bindable var model: WorkspaceModel
  let connection: Connection

  var body: some View {
    LLACard {
      VStack(alignment: .leading, spacing: LLA.Space.s) {
        HStack(spacing: LLA.Space.s) {
          RuntimeMark(kind: connection.kind)
          Text(connection.label).font(LLAFont.bodyStrong).foregroundStyle(LLA.Color.ink)
          Text(connection.kind.rawValue).llaSmallMuted()
          Spacer()
          StatusBadge(status: connection.status)
        }
        // A mirrored connection carries no path (the Mac never uploads it), so there is no row.
        if !connection.target.isEmpty { Text(connection.target).llaCodeMuted() }
        if let route = connection.routeKey {
          Text(
            "route \(route) · \(connection.b4Mode?.rawValue.replacingOccurrences(of: "_", with: " ") ?? "b4")"
          )
          .llaCodeMuted()
        }
        HStack(spacing: LLA.Space.s) {
          Text("Signed in as: \(connection.authStatus.rawValue.replacingOccurrences(of: "_", with: " "))")
            .llaSmallMuted()
          if let scope = connection.nativeScope { Text(scope).llaCodeMuted().lineLimit(1) }
          Spacer()
          Button("Check") { Task { await model.inspectConnection(id: connection.id) } }
            .buttonStyle(.llaSecondary)
            .disabled(model.busy)
          if connection.kind != .b4, connection.authStatus != .authenticated {
            Button(connection.kind == .codex ? "Sign in with ChatGPT" : "Sign in to Claude") {
              Task { await model.login(connectionId: connection.id) }
            }
            .buttonStyle(.llaPrimary)
            .disabled(model.busy || connection.status == .error)
            .accessibilityIdentifier("sign-in")
          }
        }
        .padding(.top, LLA.Space.xs)
      }
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
    VStack(alignment: .leading, spacing: LLA.Space.s) {
      LLAField("Base URL (https://host, or http://127.0.0.1:port)", text: $url)
      LLAField("Route key, for example /chat#agent", text: $route)
      LLAField("Label (optional)", text: $label)
      LLAField("Credential reference (optional, secret:…)", text: $reference)
      Text(
        "Remote endpoints must use HTTPS. Create a secret with `agent-workspace credential add <label>` and paste only its reference here; it is sent as a bearer to this origin only. The check confirms the server is reachable, not that its model credentials work."
      )
      .llaCaption().fixedSize(horizontal: false, vertical: true)
      Button("Attach B4 endpoint") {
        Task {
          await model.addConnection(
            kind: .b4, label: label.isEmpty ? nil : label, url: url, route: route,
            authReference: reference.isEmpty ? nil : reference)
        }
      }
      .buttonStyle(.llaPrimary)
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
      Grid(alignment: .leading, horizontalSpacing: LLA.Space.l, verticalSpacing: LLA.Space.xs) {
        GridRow {
          Text("Status").llaSmallMuted()
          StatusBadge(status: runtime.status)
        }
        GridRow {
          Text("Signed in").llaSmallMuted()
          Text(runtime.authStatus.rawValue.replacingOccurrences(of: "_", with: " ")).llaSmall()
        }
        GridRow {
          Text("Version").llaSmallMuted()
          Text(runtime.version ?? "unknown").llaSmall()
        }
        GridRow {
          Text("Executable").llaSmallMuted()
          Text(runtime.executablePath ?? "not found").llaCodeMuted()
        }
        if let message = runtime.message {
          GridRow {
            Text("Note").llaSmallMuted()
            Text(message).llaSmall().fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    } else {
      Text(loading ? "Checking…" : "Not checked yet.").llaSmallMuted()
    }
  }
}

struct StatusBadge: View {
  let status: ConnectionStatus

  var body: some View {
    LLABadge(status.rawValue, tone: tone, raised: true)
  }

  private var tone: LLABadge.Tone {
    switch status {
    case .ready: return .neutral
    case .error, .incompatible, .offline: return .danger
    case .connecting, .unconfigured: return .muted
    }
  }
}
