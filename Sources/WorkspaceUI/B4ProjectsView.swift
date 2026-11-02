import SwiftUI
import UniformTypeIdentifiers
import WorkspaceProtocol

/// The words on a B4 project card, kept out of the view so they are pinned by tests.
enum B4ProjectSummary {
  /// The folder with the home directory as "~".
  static func folder(_ path: String, home: String = NSHomeDirectory()) -> String {
    guard path == home || path.hasPrefix(home + "/") else { return path }
    return "~" + path.dropFirst(home.count)
  }

  /// ":3000" while running, otherwise the state in a word or two.
  static func state(_ server: LocalServer) -> String {
    switch server.health {
    case .ready: return (server.actualPort ?? server.requestedPort).map { ":\($0)" } ?? "Running"
    case .starting: return "Starting…"
    case .stopped: return "Stopped"
    case .unhealthy: return "Not responding"
    case .unknown: return "Not checked"
    }
  }

  static func mode(_ mode: LocalServerLaunchMode) -> String {
    switch mode {
    case .development: return "Dev"
    case .source: return "Source"
    }
  }
}

/// Settings → B4 projects (renamed from Local servers; settings connections design, card option A):
/// B4 apps this Mac runs on loopback, each with its status, a start or stop button, and its agents as
/// rows to connect. Attaching is the button in the Settings heading (`AttachB4ProjectSheet`).
struct B4ProjectsView: View {
  @Bindable var model: WorkspaceModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: LLA.Space.m) {
        if !WorkspaceDevice.managesWorkspace {
          Text(WorkspaceDevice.managedOnMac).llaSmallMuted().fixedSize(horizontal: false, vertical: true)
        }
        if model.servers.isEmpty {
          Text(
            WorkspaceDevice.managesWorkspace
              ? "No B4 projects yet. Attach one to run it from here." : "No B4 projects on your Mac."
          )
          .llaSmallMuted()
        }
        ForEach(model.servers) { server in
          B4ProjectCard(model: model, server: server)
        }
        if let error = model.lastError, model.settingsVisible, model.settingsPage == .servers {
          Text(error).font(LLAFont.small).foregroundStyle(LLA.Color.danger)
        }
      }
      .padding(LLA.Metrics.margin)
      .frame(maxWidth: 820, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(LLA.Color.bg)
    .navigationTitle("B4 projects")
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
        "\(pending.threadIds.count) thread(s) have a running turn on this project. Stopping loses the in-memory run; a parked prompt survives in .b4."
      )
    }
  }

  private var forceBinding: Binding<Bool> {
    Binding(
      get: { model.pendingForceStop != nil },
      set: { if !$0 { model.pendingForceStop = nil } })
  }
}

/// One B4 project: the mark and name, the status icon, a start or stop button and a "…" menu, the
/// folder with its mode and port as pills, and its agents as rows with Connect or "Connected".
struct B4ProjectCard: View {
  @Bindable var model: WorkspaceModel
  let server: LocalServer
  @State private var showingLog = false
  @Environment(\.dynamicTypeSize) private var typeSize
  @ScaledMetric(relativeTo: .body) private var markSlot: CGFloat = 24

  private var running: Bool { server.pid != nil }

  var body: some View {
    let status = LLAStatus(health: server.health)
    LLACard(fill: .surface) {
      VStack(alignment: .leading, spacing: LLA.Space.m) {
        VStack(alignment: .leading, spacing: LLA.Space.xs) {
          header(status)
          meta
        }
        if status == .attention, let message = server.statusMessage {
          HStack(alignment: .firstTextBaseline, spacing: LLA.Space.s) {
            Text(message).font(LLAFont.caption).foregroundStyle(LLA.Color.danger)
              .fixedSize(horizontal: false, vertical: true)
            if WorkspaceDevice.managesWorkspace {
              Button("Show log") { showingLog = true }.buttonStyle(.llaLink)
            }
          }
        }
        agents
      }
    }
    .sheet(isPresented: $showingLog) { ServerLogSheet(model: model, server: server) }
    .accessibilityElement(children: .contain)
  }

  /// As a connection card's: one row, or at accessibility sizes the name under the mark and controls.
  @ViewBuilder private func header(_ status: LLAStatus) -> some View {
    let name = Text(server.name).font(LLAFont.bodyStrong).foregroundStyle(LLA.Color.ink)
      .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
    let controls = HStack(spacing: LLA.Space.s) {
      LLAStatusIcon(status: status, detail: server.statusMessage)
      if WorkspaceDevice.managesWorkspace {
        startStop
        menu
      }
    }
    let mark = RuntimeMark(kind: .b4, height: 16).frame(width: markSlot, height: markSlot)
    if typeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: LLA.Space.s) {
        HStack(spacing: LLA.Space.s) {
          mark
          Spacer(minLength: LLA.Space.s)
          controls
        }
        name
      }
    } else {
      HStack(spacing: LLA.Space.s) {
        mark
        name
        Spacer(minLength: LLA.Space.s)
        controls
      }
    }
  }

  /// The folder, then the mode and the port (or the state) as pills, 4 pt under the header.
  private var meta: some View {
    let layout =
      typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: LLA.Space.xs))
      : AnyLayout(HStackLayout(spacing: LLA.Space.s))
    return layout {
      Text(B4ProjectSummary.folder(server.projectPath))
        .font(LLAFont.codeSmall).foregroundStyle(LLA.Color.muted).lineLimit(1).truncationMode(.middle)
      HStack(spacing: LLA.Space.s) {
        pill(B4ProjectSummary.mode(server.launchMode))
        if server.health == .ready {
          pill(B4ProjectSummary.state(server), mono: true)
        } else {
          Text(B4ProjectSummary.state(server)).font(LLAFont.small).foregroundStyle(LLA.Color.muted)
        }
      }
    }
    .padding(.leading, typeSize.isAccessibilitySize ? 0 : markSlot + LLA.Space.s)
  }

  private func pill(_ text: String, mono: Bool = false) -> some View {
    Text(text)
      .font(mono ? LLAFont.codeSmall : LLAFont.caption)
      .foregroundStyle(LLA.Color.ink)
      .padding(.horizontal, LLA.Space.s)
      .frame(minHeight: 20)
      .background(Capsule().fill(LLA.Color.surfaceRaised))
      .fixedSize()
  }

  private var startStop: some View {
    Button {
      Task {
        if running { await model.stopServer(id: server.id) } else { await model.startServer(id: server.id) }
      }
    } label: {
      Image(systemName: running ? "stop.fill" : "play.fill")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(LLA.Color.ink)
        .frame(width: LLA.Metrics.control, height: LLA.Metrics.control)
        .background(Circle().fill(LLA.Color.bg))
        .overlay(Circle().strokeBorder(LLA.Color.rule))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(model.busy)
    .accessibilityLabel(running ? "Stop" : "Start")
    .help(running ? "Stop" : "Start")
    .accessibilityIdentifier("server-\(running ? "stop" : "start")-\(server.name)")
  }

  private var menu: some View {
    Menu {
      Button("Restart") { Task { await model.restartServer(id: server.id) } }.disabled(!running)
      Button("Inspect agents") { Task { await model.inspectServer(id: server.id) } }
        .disabled(running && server.health == .starting)
      Button("Show log") { showingLog = true }
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(LLA.Color.muted)
        .frame(width: LLA.Metrics.control, height: LLA.Metrics.control)
        .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel("Project actions")
  }

  @ViewBuilder private var agents: some View {
    if server.routes.isEmpty {
      Text("No agents found yet. Inspect agents after adding one under src/app.")
        .font(LLAFont.caption).foregroundStyle(LLA.Color.muted)
    } else {
      VStack(spacing: 0) {
        ForEach(server.routes, id: \.key) { route in
          Rectangle().fill(LLA.Color.rule).frame(height: 1)
          HStack(spacing: LLA.Space.s) {
            Text(route.key).font(LLAFont.code).foregroundStyle(LLA.Color.ink).lineLimit(1)
              .truncationMode(.middle)
            Spacer(minLength: LLA.Space.s)
            if model.connection(serverId: server.id, route: route.key) != nil {
              Label("Connected", systemImage: "checkmark")
                .font(LLAFont.small).foregroundStyle(LLA.Color.muted)
            } else if WorkspaceDevice.managesWorkspace {
              Button("Connect") { Task { await model.connectRoute(serverId: server.id, route: route.key) } }
                .buttonStyle(.llaOutline)
                .disabled(model.busy)
                .accessibilityIdentifier("connect-\(server.name)-\(route.id)")
            }
          }
          .frame(minHeight: max(40, LLA.Metrics.row))
        }
      }
    }
  }
}

/// The redacted log tail in its own sheet, refreshed once a second while open; log lines are never
/// events.
struct ServerLogSheet: View {
  @Bindable var model: WorkspaceModel
  let server: LocalServer
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: LLA.Space.m) {
      HStack(spacing: LLA.Space.s) {
        Text("\(server.name) log").font(LLAFont.bodyStrong).foregroundStyle(LLA.Color.ink)
        Spacer(minLength: LLA.Space.s)
        Button("Done") { dismiss() }.buttonStyle(.llaSecondary).keyboardShortcut(.defaultAction)
      }
      LLACodeBlock(
        (model.serverLogs[server.id]?.lines ?? ["(no output yet)"]).joined(separator: "\n"), maxHeight: 360)
      Text("Known credential shapes are masked before the text leaves the coordinator.")
        .font(LLAFont.caption).foregroundStyle(LLA.Color.muted)
    }
    .padding(LLA.Space.xl)
    .frame(minWidth: 560)
    .background(LLA.Color.bg)
    .task(id: server.id) {
      while !Task.isCancelled {
        await model.refreshServerLogs(id: server.id)
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }
}

/// Attaching a B4 project (form option B's style): Folder, Name, Mode, Port, and Env file, each with
/// ⓘ help, and the trust warning, which is a decision rather than help, above the buttons.
struct AttachB4ProjectSheet: View {
  @Bindable var model: WorkspaceModel
  @Environment(\.dismiss) private var dismiss
  @State private var folder = ""
  @State private var name = ""
  @State private var mode: LocalServerLaunchMode = .source
  @State private var port = ""
  @State private var envFile = ""
  @State private var choosing = false
  @State private var failure: String?

  private var portValid: Bool { port.isEmpty || (Int(port).map { (1...65535).contains($0) } ?? false) }
  private var ready: Bool { !model.busy && !folder.trimmingCharacters(in: .whitespaces).isEmpty && portValid }

  var body: some View {
    LLASheet(
      title: "Attach a B4 project", lede: nil, confirmTitle: "Attach", disabled: !ready,
      cancel: { dismiss() },
      confirm: { Task { await attach() } }
    ) {
      LLAFormGroup {
        LLAFormRow(
          label: "Folder",
          info: LLAInfo(
            text:
              "The B4 app's folder, the one with b4.config. Attaching runs its config and routes with Node.",
            learnMore: HelpLink.connections("b4-project-folder"))
        ) {
          HStack(spacing: LLA.Space.s) {
            LLAFormField(placeholder: "~/repos/my-agent", text: $folder, mono: true)
            Button("Choose…") { choosing = true }.buttonStyle(.llaOutline)
          }
        }
        LLAFormRow(label: "Name") { LLAFormField(placeholder: "Optional", text: $name) }
        LLAFormRow(
          label: "Mode",
          info: LLAInfo(
            text: "Dev reloads when you save, which can replace the runtime mid-turn. Source doesn't reload.",
            learnMore: HelpLink.connections("mode"))
        ) {
          Picker("Mode", selection: $mode) {
            Text("Dev").tag(LocalServerLaunchMode.development)
            Text("Source").tag(LocalServerLaunchMode.source)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
        }
        LLAFormRow(
          label: "Port",
          info: LLAInfo(
            text: "Leave it empty to pick a free port once, when you attach.",
            learnMore: HelpLink.connections("port"))
        ) {
          LLAFormField(placeholder: "Automatic", text: $port, mono: true)
        }
        LLAFormRow(
          label: "Env file",
          info: LLAInfo(
            text: "Defaults to .env in the folder. Passed to the server; the app never reads it.",
            learnMore: HelpLink.connections("env-file"))
        ) {
          LLAFormField(placeholder: "Optional", text: $envFile, mono: true)
        }
      }
      if !portValid {
        Text("Enter a port from 1 to 65535.").font(LLAFont.caption).foregroundStyle(LLA.Color.danger)
      }
      if let failure {
        Text(failure).font(LLAFont.caption).foregroundStyle(LLA.Color.danger)
          .fixedSize(horizontal: false, vertical: true)
      }
      Text("Attaching runs this project's code. Attach only projects you trust.")
        .font(LLAFont.caption).foregroundStyle(LLA.Color.muted)
        .padding(.top, LLA.Space.s)
    }
    .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
      if case .success(let url) = result { folder = url.path }
    }
  }

  private func attach() async {
    failure = nil
    let path = (folder.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
    let before = model.servers.count
    await model.addServer(
      projectPath: path, name: name.isEmpty ? nil : name, mode: mode,
      envFilePath: envFile.isEmpty ? nil : (envFile as NSString).expandingTildeInPath, port: Int(port))
    if model.servers.count > before {
      dismiss()
    } else {
      failure = model.lastError ?? "The project could not be attached."
    }
  }
}
