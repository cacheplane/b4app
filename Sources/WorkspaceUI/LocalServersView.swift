import SwiftUI
import UniformTypeIdentifiers
import WorkspaceProtocol

/// The Local servers surface (spec 3.1): owned B4 projects with start/stop/restart, their inspected
/// routes with route connections, and a redacted log tail. Attached endpoints never appear here.
struct LocalServersView: View {
  @Bindable var model: WorkspaceModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("Registered projects").font(.headline)
        if model.servers.isEmpty {
          Text("No projects registered. Register a local B4 project below to run it from here.")
            .foregroundStyle(.secondary)
        }
        ForEach(model.servers) { server in
          ServerCard(model: model, server: server)
        }
        if let error = model.lastError, model.surface == .servers {
          Text(error).font(.callout).foregroundStyle(.red)
        }
        Text("Add project").font(.headline)
        AddProjectForm(model: model)
      }
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .navigationTitle("Local servers")
    .alert(
      "Stop while a turn is running?", isPresented: forceBinding,
      presenting: model.pendingForceStop
    ) { pending in
      Button(pending.restart ? "Restart anyway" : "Stop anyway", role: .destructive) {
        Task {
          if pending.restart {
            await model.restartServer(id: pending.serverId, force: true)
          } else {
            await model.stopServer(id: pending.serverId, force: true)
          }
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: { pending in
      Text(
        "\(pending.threadIds.count) thread(s) have a running turn on this server. Stopping loses the in-memory run; a parked prompt survives in .b4."
      )
    }
  }

  private var forceBinding: Binding<Bool> {
    Binding(
      get: { model.pendingForceStop != nil },
      set: { if !$0 { model.pendingForceStop = nil } })
  }
}

struct ServerCard: View {
  @Bindable var model: WorkspaceModel
  let server: LocalServer
  @State private var showLogs = false

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(server.name).bold()
          Text(server.launchMode.rawValue).foregroundStyle(.secondary)
          Spacer()
          ServerHealthBadge(health: server.health)
        }
        Text(server.projectPath).font(.caption.monospaced()).foregroundStyle(.secondary)
        HStack(spacing: 12) {
          Text("port \(server.requestedPort.map(String.init) ?? "-")")
          if let pid = server.pid { Text("pid \(pid)") }
          if server.ownershipVerified { Text("owned").foregroundStyle(.green) }
          Text("@b4run/cli \(server.cliVersion ?? "?")").foregroundStyle(.secondary)
        }
        .font(.caption)
        if let message = server.statusMessage {
          Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 10) {
          Button("Start") { Task { await model.startServer(id: server.id) } }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy || server.health == .ready || server.health == .starting)
            .accessibilityIdentifier("server-start-\(server.name)")
          Button("Stop") { Task { await model.stopServer(id: server.id) } }
            .disabled(model.busy || server.pid == nil)
            .accessibilityIdentifier("server-stop-\(server.name)")
          Button("Restart") { Task { await model.restartServer(id: server.id) } }
            .disabled(model.busy || server.pid == nil)
          Button("Inspect routes") { Task { await model.inspectServer(id: server.id) } }
            .disabled(model.busy || server.pid != nil && server.health == .starting)
          Spacer()
          Toggle("Logs", isOn: $showLogs).toggleStyle(.button)
        }
        Divider()
        Text("Routes").font(.subheadline).bold()
        if server.routes.isEmpty {
          Text("No routes found. Inspect again after adding one under src/app.").font(.caption)
            .foregroundStyle(.secondary)
        }
        ForEach(server.routes, id: \.key) { route in
          HStack {
            Text(route.key).font(.callout.monospaced())
            Text(route.entryFile).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let connection = model.connection(serverId: server.id, route: route.key) {
              Text("Connected: \(connection.label)").font(.caption)
              StatusBadge(status: connection.status)
            } else {
              Button("Connect") { Task { await model.connectRoute(serverId: server.id, route: route.key) } }
                .disabled(model.busy)
                .accessibilityIdentifier("connect-\(server.name)-\(route.id)")
            }
          }
        }
        if showLogs {
          Divider()
          ServerLogPanel(model: model, server: server)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// Polls the redacted tail once a second while visible; log lines are never events.
struct ServerLogPanel: View {
  @Bindable var model: WorkspaceModel
  let server: LocalServer

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Log").font(.subheadline).bold()
        if let path = server.logPath {
          Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(
            .middle)
        }
      }
      ScrollView {
        Text((model.serverLogs[server.id]?.lines ?? ["(no output yet)"]).joined(separator: "\n"))
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 220)
      Text("Known credential shapes are masked before the text leaves the coordinator.").font(.caption2)
        .foregroundStyle(.secondary)
    }
    .task(id: server.id) {
      while !Task.isCancelled {
        await model.refreshServerLogs(id: server.id)
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }
}

struct ServerHealthBadge: View {
  let health: LocalServerHealth

  var body: some View {
    Text(health.rawValue)
      .font(.caption)
      .padding(.horizontal, 8)
      .padding(.vertical, 2)
      .background(color.opacity(0.15), in: Capsule())
      .foregroundStyle(color)
  }

  private var color: Color {
    switch health {
    case .ready: return .green
    case .starting, .unknown: return .orange
    case .stopped: return .gray
    case .unhealthy: return .red
    }
  }
}

/// Registers a project. Registration is the trust decision: inspection runs the project's config
/// and route modules with Node (design "Trust and inspection").
struct AddProjectForm: View {
  @Bindable var model: WorkspaceModel
  @State private var projectPath = ""
  @State private var name = ""
  @State private var mode: LocalServerLaunchMode = .source
  @State private var envFilePath = ""
  @State private var port = ""
  @State private var choosing = false

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          TextField("Project directory (the B4 app root)", text: $projectPath).textFieldStyle(.roundedBorder)
          Button("Choose…") { choosing = true }
        }
        TextField("Name (optional, defaults to the directory name)", text: $name).textFieldStyle(
          .roundedBorder)
        Picker("Mode", selection: $mode) {
          Text("Source (b4 start, no reload)").tag(LocalServerLaunchMode.source)
          Text("Development (b4 dev, hot reload)").tag(LocalServerLaunchMode.development)
        }
        TextField("Env file (optional, defaults to <project>/.env when present)", text: $envFilePath)
          .textFieldStyle(.roundedBorder)
        TextField("Port (optional, allocated once when empty)", text: $port).textFieldStyle(.roundedBorder)
        Text(
          "Registering runs the project's b4.config and route modules with Node to discover routes, and starting it runs the project; register only projects you trust. The server binds 127.0.0.1; the env file is passed to the server and never read into the app. Development mode can replace the runtime mid-turn when a file changes."
        )
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Button("Register project") {
          Task {
            await model.addServer(
              projectPath: projectPath, name: name.isEmpty ? nil : name, mode: mode,
              envFilePath: envFilePath.isEmpty ? nil : envFilePath, port: Int(port))
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.busy || projectPath.isEmpty || (!port.isEmpty && Int(port) == nil))
        .accessibilityIdentifier("add-server")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
      if case .success(let url) = result { projectPath = url.path }
    }
  }
}
