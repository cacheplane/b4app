import SwiftUI
import WorkspaceProtocol

/// Where each "Learn more" goes: a section of `docs/help/connections.md` in the repository.
enum HelpLink {
  static func connections(_ anchor: String) -> URL? {
    URL(string: "https://github.com/cacheplane/b4app/blob/main/docs/help/connections.md#\(anchor)")
  }
}

/// The B4 form's checks, kept out of the view so the copy is pinned by tests.
enum B4ConnectionForm {
  /// What is wrong with the server address, or nil: remote servers must use HTTPS (loopback may use
  /// HTTP), and the address needs its scheme. Nothing is said about an empty field.
  static func serverProblem(_ server: String) -> String? {
    let text = server.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), let host = url.host(),
      !host.isEmpty, ["http", "https"].contains(scheme)
    else { return "Enter a full address, like https://host." }
    if scheme == "http", !["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased()) {
      return "Remote servers need HTTPS."
    }
    return nil
  }

  static func ready(server: String, agent: String) -> Bool {
    !server.trimmingCharacters(in: .whitespaces).isEmpty && serverProblem(server) == nil
      && !agent.trimmingCharacters(in: .whitespaces).isEmpty
  }
}

/// Adding or editing a B4 connection (settings connections design, form option B): Name, Server,
/// Agent, and API key, with ⓘ help on the fields that need it. Editing keeps the connection's identity:
/// Server and Agent are read-only, and the key can be replaced or removed but never shown.
struct B4ConnectionSheet: View {
  @Bindable var model: WorkspaceModel
  /// Nil adds a connection.
  let connection: Connection?
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var server: String
  @State private var agent: String
  @State private var key = ""
  @State private var replacingKey = false
  @State private var removingKey = false
  @State private var failure: String?

  init(model: WorkspaceModel, connection: Connection?) {
    self.model = model
    self.connection = connection
    _name = State(initialValue: connection?.label ?? "")
    _server = State(initialValue: connection?.target ?? "")
    _agent = State(initialValue: connection?.routeKey ?? "/chat#agent")
  }

  private var editing: Bool { connection != nil }
  private var title: String { editing ? "Edit B4 connection" : "Add a B4 connection" }
  private var canSave: Bool {
    !model.busy && (editing || B4ConnectionForm.ready(server: server, agent: agent))
  }

  var body: some View {
    LLASheet(
      title: title, lede: editing ? nil : "Connect to a B4 agent server.",
      confirmTitle: editing ? "Save" : "Add",
      disabled: !canSave, cancel: close, confirm: { Task { await save() } }
    ) {
      LLAFormGroup {
        LLAFormRow(label: "Name") {
          LLAFormField(placeholder: "Optional", text: $name)
        }
        LLAFormRow(label: "Server") {
          if editing {
            Text(server).font(LLAFont.code).foregroundStyle(LLA.Color.muted).lineLimit(1).truncationMode(
              .middle)
          } else {
            LLAFormField(placeholder: "https://agents.example.com", text: $server, mono: true)
          }
        }
        LLAFormRow(label: "Agent", info: agentInfo) {
          if editing {
            Text(agent).font(LLAFont.code).foregroundStyle(LLA.Color.muted).lineLimit(1)
          } else {
            LLAFormField(placeholder: "/chat#agent", text: $agent, mono: true)
          }
        }
        LLAFormRow(label: "API key", info: keyInfo) { keyField }
      }
      if let problem = B4ConnectionForm.serverProblem(server), !editing {
        Text(problem).font(LLAFont.caption).foregroundStyle(LLA.Color.danger)
      }
      if let failure {
        Text(failure).font(LLAFont.caption).foregroundStyle(LLA.Color.danger)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  @ViewBuilder private var keyField: some View {
    if editing, connection?.authReference != nil, !replacingKey {
      HStack(spacing: LLA.Space.s) {
        Text(removingKey ? "Removed on save" : "Saved in Keychain")
          .font(LLAFont.small).foregroundStyle(LLA.Color.muted)
        Spacer(minLength: 0)
        if !removingKey {
          Button("Replace") { replacingKey = true }.buttonStyle(.llaLink)
        }
        Button(removingKey ? "Keep" : "Remove") { removingKey.toggle() }.buttonStyle(.llaLink)
      }
    } else {
      LLAFormField(placeholder: "Optional", text: $key, mono: true, secure: true)
    }
  }

  private var agentInfo: LLAInfo {
    LLAInfo(
      text: editing
        ? "Another server or agent is a new connection, so these stay as they are."
        : "The route your B4 server exposes for the agent, such as /chat#agent.",
      learnMore: HelpLink.connections("agent"))
  }

  private var keyInfo: LLAInfo {
    LLAInfo(
      text: "Sent as a bearer token to this server only. It is kept in your Keychain and never shown again.",
      learnMore: HelpLink.connections("api-key"))
  }

  private func save() async {
    failure = nil
    let typedKey = key
    // The key leaves the view's state as soon as it is sent, whether or not the save works.
    key = ""
    let label = name.trimmingCharacters(in: .whitespaces)
    let saved: Bool
    if let connection {
      saved = await model.updateConnection(
        id: connection.id, label: label.isEmpty ? nil : label, apiKey: typedKey.isEmpty ? nil : typedKey,
        clearKey: removingKey)
    } else {
      saved =
        await model.addB4Connection(
          label: label.isEmpty ? nil : label, url: server.trimmingCharacters(in: .whitespaces),
          route: agent.trimmingCharacters(in: .whitespaces), apiKey: typedKey.isEmpty ? nil : typedKey) != nil
    }
    if saved {
      close()
    } else {
      failure = model.lastError ?? "The connection could not be saved."
    }
  }

  private func close() {
    key = ""
    dismiss()
  }
}

/// Renaming a Codex or Claude connection: its name is all Edit can change (its account is its sign-in).
struct ConnectionNameSheet: View {
  @Bindable var model: WorkspaceModel
  let connection: Connection
  @Environment(\.dismiss) private var dismiss
  @State private var name: String

  init(model: WorkspaceModel, connection: Connection) {
    self.model = model
    self.connection = connection
    _name = State(initialValue: connection.label)
  }

  var body: some View {
    LLASheet(
      title: "Edit \(connection.kind == .codex ? "Codex" : "Claude") connection", lede: nil,
      confirmTitle: "Save",
      disabled: model.busy || name.trimmingCharacters(in: .whitespaces).isEmpty, cancel: { dismiss() },
      confirm: {
        Task {
          if await model.updateConnection(id: connection.id, label: name, apiKey: nil, clearKey: false) {
            dismiss()
          }
        }
      }
    ) {
      LLAFormGroup {
        LLAFormRow(label: "Name") { LLAFormField(placeholder: "Name", text: $name) }
      }
    }
  }
}

/// A sheet's frame. On the Mac: 24 pt margins, the title and an optional one-line lede, the content
/// 16 pt below, and Cancel and the action 24 pt below that, 480 wide. On the phone: a navigation stack
/// with an inline title and Cancel and the action in the bar.
struct LLASheet<Content: View>: View {
  let title: String
  let lede: String?
  let confirmTitle: String
  let disabled: Bool
  let cancel: () -> Void
  let confirm: () -> Void
  @ViewBuilder var content: Content

  var body: some View {
    #if os(iOS)
      NavigationStack {
        ScrollView {
          VStack(alignment: .leading, spacing: LLA.Space.s) { content }
            .padding(LLA.Metrics.margin)
        }
        .background(LLA.Color.bg)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
          ToolbarItem(placement: .confirmationAction) {
            Button(confirmTitle, action: confirm).disabled(disabled)
          }
        }
      }
      .tint(LLA.Color.accent)
    #else
      VStack(alignment: .leading, spacing: 0) {
        Text(title).font(LLAFont.bodyStrong).foregroundStyle(LLA.Color.ink)
        if let lede {
          Text(lede).font(LLAFont.small).foregroundStyle(LLA.Color.muted).padding(.top, LLA.Space.xs)
        }
        VStack(alignment: .leading, spacing: LLA.Space.s) { content }
          .padding(.top, LLA.Space.l)
        LLASheetBar(confirmTitle: confirmTitle, disabled: disabled, cancel: cancel, confirm: confirm)
          .padding(.top, LLA.Space.xl)
      }
      .padding(LLA.Space.xl)
      .frame(width: 480)
      .background(LLA.Color.bg)
      .tint(LLA.Color.accent)
    #endif
  }
}
