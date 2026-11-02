import SwiftUI
import WorkspaceProtocol

/// Settings → Connections (settings connections design): a card per connection with its state as an
/// icon and its usage, checked when the page opens. Adding is the "+" in the Settings heading
/// (`ConnectionAddMenu`); editing is each card's "…" menu. The phone shows the cards read-only.
struct ConnectionsView: View {
  @Bindable var model: WorkspaceModel
  @State private var editing: Connection?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: LLA.Space.m) {
        if !WorkspaceDevice.managesWorkspace {
          Text(WorkspaceDevice.managedOnMac).llaSmallMuted().fixedSize(horizontal: false, vertical: true)
        }
        if let error = model.diagnosticsError {
          Text(error).font(LLAFont.small).foregroundStyle(LLA.Color.danger)
        }
        if model.connections.isEmpty {
          Text(
            WorkspaceDevice.managesWorkspace
              ? "No connections yet. Add Codex, Claude, or a B4 agent with +." : "No connections yet."
          )
          .llaSmallMuted()
        }
        ForEach(model.connections) { connection in
          ConnectionCardView(model: model, connection: connection) { editing = connection }
        }
        if let error = model.lastError, model.settingsVisible, model.settingsPage == .connections {
          Text(error).font(LLAFont.small).foregroundStyle(LLA.Color.danger)
        }
      }
      .padding(LLA.Metrics.margin)
      .frame(maxWidth: 820, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(LLA.Color.bg)
    .navigationTitle("Connections")
    .sheet(item: $editing) { connection in
      if connection.kind == .b4 {
        B4ConnectionSheet(model: model, connection: connection)
      } else {
        ConnectionNameSheet(model: model, connection: connection)
      }
    }
    .task(id: model.link) {
      guard model.link == .ready else { return }
      await model.refreshUsage()
      guard WorkspaceDevice.managesWorkspace else { return }
      if model.diagnostics == nil { await model.refreshDiagnostics() }
      // A check per connection when the page opens, in the background so nothing waits on it; each card
      // shows its own progress. A connection with a turn in progress is plainly working, so it is left
      // alone, and one checked in the last two minutes is not checked again.
      let busy = Set(
        model.activeTurns.keys.compactMap { id in model.threads.first { $0.id == id }?.connectionId })
      for connection in model.connections where !busy.contains(connection.id) {
        await model.checkInBackground(id: connection.id)
      }
    }
  }
}

/// The "+" in the Settings heading: Codex and Claude go straight to their sign-in; B4 opens its form.
/// A runtime that is not installed is listed but disabled, with the reason beneath.
struct ConnectionAddMenu: View {
  @Bindable var model: WorkspaceModel
  let addB4: () -> Void

  var body: some View {
    Menu {
      runtime(.codex, title: "Codex")
      runtime(.claude, title: "Claude")
      Button("B4 agent…", action: addB4)
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(LLA.Color.ink)
        .frame(width: LLA.Metrics.control, height: LLA.Metrics.control)
        .background(Circle().fill(LLA.Color.surface))
        .overlay(Circle().strokeBorder(LLA.Color.rule))
        .contentShape(Circle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel("Add connection")
    .help("Add connection")
    .disabled(model.link != .ready || model.busy)
  }

  @ViewBuilder private func runtime(_ kind: ConnectionKind, title: String) -> some View {
    let runtime = model.diagnostics?.runtimes.first { $0.kind.rawValue == kind.rawValue }
    let missing = runtime.map { $0.executablePath == nil } ?? false
    Button {
      Task { await add(kind) }
    } label: {
      Text(title)
      if missing { Text("Not installed. See Diagnostics.") }
    }
    .disabled(missing)
  }

  private func add(_ kind: ConnectionKind) async {
    guard let added = await model.addConnection(kind: kind) else { return }
    if added.authStatus != .authenticated, added.status == .ready || added.authStatus == .required {
      await model.login(connectionId: added.id)
    }
    await model.refreshUsage()
  }
}
