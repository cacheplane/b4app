import SwiftUI
import WorkspaceProtocol

struct ThreadsView: View {
  @Bindable var model: WorkspaceModel

  var body: some View {
    if let thread = model.threads.first(where: { $0.id == model.selectedThreadId }) {
      ThreadDetailView(model: model, thread: thread)
    } else {
      LLAEmptyState(
        "Threads",
        text: model.connections.isEmpty
          ? "Add a connection to start a conversation with Codex, Claude Code, or a B4 agent."
          : "Select a thread in the sidebar, or start a new one."
      ) {
        if model.conversationReadyConnections.isEmpty {
          Button("Add connection") { model.openSettings(.connections) }
            .buttonStyle(.llaPrimary)
            .accessibilityIdentifier("add-connection")
        } else {
          Button("New thread") { model.showNewThread = true }
            .buttonStyle(.llaPrimary)
            .accessibilityIdentifier("new-thread")
        }
      }
      .navigationTitle("Threads")
    }
  }
}

struct ThreadDetailView: View {
  @Bindable var model: WorkspaceModel
  let thread: ConversationThread
  @State private var renaming = false
  @State private var newTitle = ""
  @Environment(\.dynamicTypeSize) private var typeSize

  private var connection: Connection? { model.connection(id: thread.connectionId) }

  var body: some View {
    VStack(spacing: 0) {
      header
      Hairline()
      if let detail = model.detail, detail.thread.id == thread.id {
        #if os(iOS)
          // The transcript scrolls on under the composer, behind the system's soft scroll edge, as in
          // Messages; a rule or a hard cut above the field is not needed.
          TranscriptView(detail: detail)
            .safeAreaBar(edge: .bottom, spacing: 0) { bottom(detail) }
        #else
          TranscriptView(detail: detail)
          Hairline()
          bottom(detail)
        #endif
      } else if model.detailLoading {
        ProgressView("Loading thread…").llaSmallMuted().padding(LLA.Space.xxl)
        Spacer(minLength: 0)
      } else {
        Text(model.lastError ?? "Thread not loaded.").llaMuted().padding(LLA.Space.xxl)
        Spacer(minLength: 0)
      }
    }
    .navigationTitle(thread.title.isEmpty ? "Untitled" : thread.title)
    #if os(iOS)
      // A pushed detail takes the inline title (HIG, Navigation bars); the header below drops its own
      // copy, so the transcript starts under one title rather than two.
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .task(id: thread.id) {
      if model.detail?.thread.id != thread.id { await model.openThread(id: thread.id) }
    }
    .toolbar {
      #if os(macOS)
        ToolbarItemGroup { threadActions }
      #else
        // One overflow menu on the phone, so the inline title keeps the bar's width (HIG, Toolbars:
        // the most important items in the bar, the rest in a More menu).
        ToolbarItem {
          Menu("Thread actions", systemImage: "ellipsis") { threadActions }
            .accessibilityIdentifier("thread-actions")
        }
      #endif
    }
    .alert("Rename thread", isPresented: $renaming) {
      TextField("Title", text: $newTitle)
      Button("Rename") { Task { await model.updateThread(id: thread.id, title: newTitle) } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The title is local to this app; the runtime's own history is not changed.")
    }
  }

  /// Pending requests, the continuity banner, and the composer, under the transcript.
  @ViewBuilder private func bottom(_ detail: ThreadDetail) -> some View {
    VStack(spacing: 0) {
      if !detail.requests.isEmpty {
        RuntimeRequestList(model: model, requests: detail.requests)
        Hairline()
      }
      if thread.continuity != .available {
        ContinuityBanner(model: model, thread: thread)
      }
      ComposerView(model: model, detail: detail)
    }
  }

  /// Rename, Pin, Archive: toolbar buttons on the Mac, the overflow menu's items on the phone.
  @ViewBuilder private var threadActions: some View {
    Button("Rename", systemImage: "pencil") {
      newTitle = thread.title
      renaming = true
    }
    .accessibilityIdentifier("rename")
    Button(thread.pinned ? "Unpin" : "Pin", systemImage: thread.pinned ? "pin.slash" : "pin") {
      Task { await model.updateThread(id: thread.id, pinned: !thread.pinned) }
    }
    .accessibilityIdentifier("pin")
    Button(
      thread.archived ? "Unarchive" : "Archive",
      systemImage: thread.archived ? "tray.and.arrow.up" : "archivebox"
    ) {
      Task { await model.updateThread(id: thread.id, archived: !thread.archived) }
    }
    .accessibilityIdentifier("archive")
  }

  /// Connection, kind, and directory or route; "on <device>" when the phone's mirror knows the Mac
  /// that owns the thread (the Mac itself reports none).
  private var subtitle: String {
    #if os(iOS)
      // The phone's line is short enough to read whole: the connection (its kind only when the label
      // does not already say it), the folder's name rather than its path, and the Mac.
      var parts = [connection?.label ?? "Unknown connection"]
      if let kind = connection?.kind.rawValue, kind.caseInsensitiveCompare(parts[0]) != .orderedSame {
        parts.append(kind)
      }
      if connection?.kind == .b4 {
        parts.append("route \(thread.context ?? "?")")
      } else if let context = thread.context, !context.isEmpty {
        parts.append((context as NSString).lastPathComponent)
      }
    #else
      var parts = [
        connection?.label ?? "Unknown connection", connection?.kind.rawValue ?? "?",
        connection?.kind == .b4 ? "route \(thread.context ?? "?")" : (thread.context ?? "no directory"),
      ]
    #endif
    if let device = thread.ownerDeviceName, !device.isEmpty { parts.append("on \(device)") }
    return parts.joined(separator: " · ")
  }

  #if os(macOS)
    private var header: some View {
      VStack(alignment: .leading, spacing: LLA.Space.xs) {
        HStack(alignment: .firstTextBaseline, spacing: LLA.Space.m) {
          Text(thread.title.isEmpty ? "Untitled" : thread.title).llaDisplay().lineLimit(1)
          if thread.archived { LLABadge("Archived") }
          Spacer()
          turnBadge
        }
        Text(subtitle).llaSmallMuted().lineLimit(1).truncationMode(.middle)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, LLA.Metrics.margin)
      .padding(.vertical, LLA.Space.l)
    }
  #else
    /// Where the thread runs and its state, under the navigation bar's title. The badges move below
    /// the line at accessibility sizes, where the line wraps instead of truncating.
    private var header: some View {
      let stacked = typeSize.isAccessibilitySize
      let layout =
        stacked
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: LLA.Space.xs))
        : AnyLayout(HStackLayout(alignment: .center, spacing: LLA.Space.s))
      return layout {
        Text(subtitle).llaSmallMuted().lineLimit(stacked ? 3 : 1).truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
        if thread.archived { LLABadge("Archived") }
        turnBadge
      }
      .padding(.horizontal, LLA.Metrics.margin)
      .padding(.vertical, LLA.Space.s)
    }
  #endif

  @ViewBuilder private var turnBadge: some View {
    if let turn = model.detail?.activeTurn, model.detail?.thread.id == thread.id {
      TurnStatusBadge(turn: turn)
    }
  }
}

/// Spec 3.3: when the native session is gone or belongs to another identity, keep the cached view,
/// say so, and offer a new thread. The composer stays disabled.
struct ContinuityBanner: View {
  @Bindable var model: WorkspaceModel
  let thread: ConversationThread

  var body: some View {
    LLACard(fill: .surface) {
      HStack(alignment: .top, spacing: LLA.Space.l) {
        VStack(alignment: .leading, spacing: LLA.Space.xs) {
          Text("Continuation is unavailable").font(LLAFont.bodyStrong).foregroundStyle(LLA.Color.ink)
          Text(explanation).llaSmallMuted()
        }
        Spacer()
        Button("Check again") { Task { await model.reconcileThread(id: thread.id) } }
          .buttonStyle(.llaSecondary)
          .disabled(model.busy)
        Button("New thread") { model.showNewThread = true }
          .buttonStyle(.llaPrimary)
          .disabled(model.conversationReadyConnections.isEmpty)
      }
    }
    .padding(.horizontal, LLA.Metrics.margin)
    .padding(.top, LLA.Space.l)
    .frame(maxWidth: LLA.Metrics.column)
    .frame(maxWidth: .infinity)
    .accessibilityIdentifier("continuity-banner")
  }

  private var explanation: String {
    switch thread.continuity {
    case .available: return ""
    case .missing:
      return
        "The runtime no longer has this thread's native session. The cached transcript stays; nothing was re-sent."
    case .identityChanged:
      let now = model.connection(id: thread.connectionId)?.nativeScope ?? "another identity"
      return
        "This thread was created under \(thread.nativeScope); the connection is now \(now). Old threads are never retargeted to a different account or server."
    }
  }
}

struct TurnStatusBadge: View {
  let turn: Turn

  var body: some View {
    HStack(spacing: 6) {
      if turn.status == .running || turn.status == .submitting || turn.status == .stopping {
        ProgressView().controlSize(.mini)
      }
      Text(text).lineLimit(1).fixedSize()
    }
    .font(LLAFont.caption)
    .foregroundStyle(turn.status == .waitingForUser ? LLA.Color.accent : LLA.Color.ink)
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .background(Capsule().fill(LLA.Color.surface))
    .accessibilityIdentifier("turn-status")
  }

  private var text: String {
    switch turn.status {
    case .submitting: return "Sending…"
    case .running: return "Running"
    case .waitingForUser: return "Waiting for you"
    case .stopping: return "Stopping…"
    case .reconciling: return "Outcome unknown"
    case .terminal: return turn.outcome?.rawValue ?? "finished"
    }
  }
}
