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
          LLAFacts {
            row("Version", "\(report.coordinator.version) (pid \(report.coordinator.pid))")
            row("Started", report.coordinator.startedAt)
            row("Epoch", "\(report.coordinator.epoch) @ \(report.coordinator.sequence)", mono: true)
            row("Socket", report.coordinator.socketPath, mono: true)
            row("Database", report.coordinator.databasePath, mono: true)
            row("Host", "\(report.host.platform) \(report.host.arch) (\(report.host.release))")
          }
          if let sync = report.sync {
            LLASectionHead("Sync").padding(.top, LLA.Space.l)
            LLAFacts {
              row("Hub", sync.hubURL, mono: true)
              row("Device", sync.deviceName)
              row("Cursor", "\(sync.cursor)", mono: true)
              row("Last sync", sync.lastSyncAt ?? "never")
              if let error = sync.lastError { row("Last error", error) }
              row("Unreadable rows", "\(sync.undecodableRows)", mono: true)
              row("Waiting to upload", Self.uploads(sync.pendingUploads, "waiting to upload"), mono: false)
              row("Refused by the hub", Self.uploads(sync.refusedUploads, "refused"), mono: false)
            }
          }
          if let relay = report.relay {
            LLASectionHead("Relay link").padding(.top, LLA.Space.l)
            Grid(alignment: .leading, horizontalSpacing: LLA.Space.l, verticalSpacing: LLA.Space.xs) {
              row("State", relay.state.rawValue.capitalized)
              if let since = relay.since { row("Since", since) }
              if let error = relay.lastError { row("Last error", error) }
            }
          }
          if let held = report.keepAwakeHeld {
            LLASectionHead("Keep awake").padding(.top, LLA.Space.l)
            Grid(alignment: .leading, horizontalSpacing: LLA.Space.l, verticalSpacing: LLA.Space.xs) {
              row("Keeping Mac awake", held ? "Yes" : "No")
            }
          }
          if let deletes = report.threadDeletes {
            // Deleted threads whose runtime copy is not deleted yet, or cannot be: counts, never titles.
            LLASectionHead("Deleted threads").padding(.top, LLA.Space.l)
            let lines = Self.threadDeletes(deletes)
            if lines.isEmpty {
              Text("Every runtime copy is deleted.").llaMuted()
            } else {
              LLAFacts {
                ForEach(lines, id: \.runtime) { line in row(line.runtime, line.value) }
              }
            }
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
      .padding(LLA.Metrics.margin)
      .frame(maxWidth: 820, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(LLA.Color.bg)
    .navigationTitle("Diagnostics")
    .modifier(
      SettingsPageAction(title: "Refresh", disabled: model.link != .ready || model.diagnosticsLoading) {
        Task { await model.refreshDiagnostics() }
      }
    )
    .task(id: model.link) {
      if model.link == .ready, model.diagnostics == nil { await model.refreshDiagnostics() }
    }
  }

  /// One runtime's deletes still to do: "2 waiting", "1 waiting, 3 not supported".
  struct ThreadDeleteLine: Equatable {
    var runtime: String
    var value: String
  }

  static func threadDeletes(_ summaries: [ThreadDeleteSummary]) -> [ThreadDeleteLine] {
    summaries.compactMap { summary in
      var parts: [String] = []
      if summary.waiting > 0 { parts.append("\(summary.waiting) waiting") }
      if summary.unsupported > 0 { parts.append("\(summary.unsupported) not supported") }
      guard !parts.isEmpty else { return nil }
      let runtime: String
      switch summary.kind {
      case .codex: runtime = "Codex"
      case .claude: runtime = "Claude Code"
      case .b4: runtime = "B4"
      }
      return ThreadDeleteLine(runtime: runtime, value: parts.joined(separator: ", "))
    }
  }

  /// "None", "1 change waiting to upload", "2 changes refused".
  static func uploads(_ count: Int, _ what: String) -> String {
    count == 0 ? "None" : "\(count) \(count == 1 ? "change" : "changes") \(what)"
  }

  @ViewBuilder private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
    LLAFact(label) {
      Group {
        if mono { Text(value).llaCodeMuted().foregroundStyle(LLA.Color.ink) } else { Text(value).llaSmall() }
      }
      .textSelection(.enabled)
    }
  }
}

/// A connection status in words, for Diagnostics' runtime table.
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
