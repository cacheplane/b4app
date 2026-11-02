import SwiftUI
import UniformTypeIdentifiers
import WorkspaceProtocol

/// The Local servers surface (spec 3.1): owned B4 projects with start/stop/restart, their inspected
/// routes with route connections, and a redacted log tail. Attached endpoints never appear here.
struct LocalServersView: View {
  @Bindable var model: WorkspaceModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: LLA.Space.xl) {
        LLASectionHead(
          "Registered projects",
          intro: WorkspaceDevice.managesWorkspace
            ? "B4 projects this app runs on loopback. Attached servers and remote endpoints live under Connections."
            : "B4 projects your Mac runs on loopback. \(WorkspaceDevice.managedOnMac)"
        )
        if model.servers.isEmpty {
          Text(
            WorkspaceDevice.managesWorkspace
              ? "No projects registered. Register a local B4 project below to run it from here."
              : "No projects registered on your Mac."
          )
          .llaMuted()
        }
        ForEach(model.servers) { server in
          ServerCard(model: model, server: server)
        }
        if let error = model.lastError, model.settingsVisible, model.settingsPage == .servers {
          Text(error).font(LLAFont.small).foregroundStyle(LLA.Color.danger)
        }
        if WorkspaceDevice.managesWorkspace {
          LLASectionHead("Add a project").padding(.top, LLA.Space.l)
          AddProjectForm(model: model)
        }
      }
      .padding(LLA.Metrics.margin)
      .frame(maxWidth: 820, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(LLA.Color.bg)
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
    LLACard {
      VStack(alignment: .leading, spacing: LLA.Space.s) {
        HStack(spacing: LLA.Space.s) {
          Text(server.name).font(LLAFont.bodyStrong).foregroundStyle(LLA.Color.ink)
          Text(server.launchMode.rawValue).llaSmallMuted()
          Spacer()
          ServerHealthBadge(health: server.health)
        }
        Text(server.projectPath).llaCodeMuted()
        HStack(spacing: LLA.Space.m) {
          Text("port \(server.requestedPort.map(String.init) ?? "-")")
          if let pid = server.pid { Text("pid \(pid)") }
          if server.ownershipVerified { Text("owned") }
          Text("@b4run/cli \(server.cliVersion ?? "?")")
        }
        .llaCaption()
        if let message = server.statusMessage {
          Text(message).llaSmall().fixedSize(horizontal: false, vertical: true)
        }
        if WorkspaceDevice.managesWorkspace { controls }
        Hairline().padding(.vertical, LLA.Space.xs)
        Text("Routes").font(LLAFont.smallStrong).foregroundStyle(LLA.Color.ink)
        if server.routes.isEmpty {
          Text("No routes found. Inspect again after adding one under src/app.").llaCaption()
        }
        ForEach(Array(server.routes.enumerated()), id: \.element.key) { index, route in
          if index > 0 { Hairline() }
          HStack(spacing: LLA.Space.s) {
            Text(route.key).llaCode()
            Text(route.entryFile).llaCaption()
            Spacer()
            if let connection = model.connection(serverId: server.id, route: route.key) {
              Text("Connected: \(connection.label)").llaCaption()
              StatusBadge(status: connection.status)
            } else if WorkspaceDevice.managesWorkspace {
              Button("Connect") { Task { await model.connectRoute(serverId: server.id, route: route.key) } }
                .buttonStyle(.llaSecondary)
                .disabled(model.busy)
                .accessibilityIdentifier("connect-\(server.name)-\(route.id)")
            }
          }
          .padding(.vertical, LLA.Space.xs)
        }
        if showLogs {
          Hairline().padding(.vertical, LLA.Space.xs)
          ServerLogPanel(model: model, server: server)
        }
      }
    }
  }

  /// Start, Stop, Restart, Inspect routes, and the log: the Mac only.
  private var controls: some View {
    HStack(spacing: LLA.Space.s) {
      Button("Start") { Task { await model.startServer(id: server.id) } }
        .buttonStyle(.llaPrimary)
        .disabled(model.busy || server.pid != nil)
        .accessibilityIdentifier("server-start-\(server.name)")
      Button("Stop") { Task { await model.stopServer(id: server.id) } }
        .buttonStyle(.llaSecondary)
        .disabled(model.busy || server.pid == nil)
        .accessibilityIdentifier("server-stop-\(server.name)")
      Button("Restart") { Task { await model.restartServer(id: server.id) } }
        .buttonStyle(.llaSecondary)
        .disabled(model.busy || server.pid == nil)
      Button("Inspect routes") { Task { await model.inspectServer(id: server.id) } }
        .buttonStyle(.llaSecondary)
        .disabled(model.busy || server.pid != nil && server.health == .starting)
      Spacer()
      Button(showLogs ? "Hide log" : "Show log") { showLogs.toggle() }.buttonStyle(.llaLink)
    }
    .padding(.top, LLA.Space.xs)
  }
}

/// Polls the redacted tail once a second while visible; log lines are never events.
struct ServerLogPanel: View {
  @Bindable var model: WorkspaceModel
  let server: LocalServer

  var body: some View {
    VStack(alignment: .leading, spacing: LLA.Space.xs) {
      HStack(spacing: LLA.Space.s) {
        Text("Log").font(LLAFont.smallStrong).foregroundStyle(LLA.Color.ink)
        if let path = server.logPath {
          Text(path).llaCodeMuted().lineLimit(1).truncationMode(.middle)
        }
      }
      LLACodeBlock(
        (model.serverLogs[server.id]?.lines ?? ["(no output yet)"]).joined(separator: "\n"), maxHeight: 220)
      Text("Known credential shapes are masked before the text leaves the coordinator.").llaCaption()
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
    LLABadge(health.rawValue, tone: tone, raised: true)
  }

  private var tone: LLABadge.Tone {
    switch health {
    case .ready: return .neutral
    case .starting, .unknown, .stopped: return .muted
    case .unhealthy: return .danger
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
    LLACard {
      VStack(alignment: .leading, spacing: LLA.Space.s) {
        HStack(spacing: LLA.Space.s) {
          LLAField("Project directory (the B4 app root)", text: $projectPath)
          Button("Choose…") { choosing = true }.buttonStyle(.llaSecondary)
        }
        LLAField("Name (optional, defaults to the directory name)", text: $name)
        HStack(spacing: LLA.Space.s) {
          Text("Mode").llaSmallMuted()
          Picker("Mode", selection: $mode) {
            Text("Source (b4 start, no reload)").tag(LocalServerLaunchMode.source)
            Text("Development (b4 dev, hot reload)").tag(LocalServerLaunchMode.development)
          }
          .labelsHidden()
          .font(LLAFont.small)
        }
        LLAField("Env file (optional, defaults to <project>/.env when present)", text: $envFilePath)
        LLAField("Port (optional, allocated once when empty)", text: $port)
        Text(
          "Registering runs the project's b4.config and route modules with Node to discover routes, and starting it runs the project; register only projects you trust. The server binds 127.0.0.1; the env file is passed to the server and never read into the app. Development mode can replace the runtime mid-turn when a file changes."
        )
        .llaCaption().fixedSize(horizontal: false, vertical: true)
        Button("Register project") {
          Task {
            await model.addServer(
              projectPath: projectPath, name: name.isEmpty ? nil : name, mode: mode,
              envFilePath: envFilePath.isEmpty ? nil : envFilePath, port: Int(port))
          }
        }
        .buttonStyle(.llaPrimary)
        .disabled(model.busy || projectPath.isEmpty || (!port.isEmpty && Int(port) == nil))
        .accessibilityIdentifier("add-server")
      }
    }
    .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
      if case .success(let url) = result { projectPath = url.path }
    }
  }
}
