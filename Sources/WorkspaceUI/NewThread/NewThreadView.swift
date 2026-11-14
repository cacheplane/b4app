import SwiftUI
import UniformTypeIdentifiers
import WorkspaceProtocol

/// A new thread from a blank composer (the new-thread composer spec, "The Mac" and "The iPhone"): a
/// headline, the field, the picker row under it (at dense, on the Mac, one line naming its choices), and
/// the draft's start status. Nothing exists until Send, which creates the thread, starts its first turn,
/// and opens it. The draft is the device's one `newThreadDraft`, so its text and choices outlive this
/// screen.
///
/// The Mac (and any regular width) centres the headline and the field in the reading column, the
/// headline centred over the field (the thread list and environments design, "Starting a thread"); a
/// compact width pins the field and the row to the bottom, above the keyboard, under the "New thread"
/// title. On the Mac the place picker opens the place palette over this view, which it veils.
struct NewThreadView: View {
  @Bindable var model: WorkspaceModel
  @FocusState private var focused: Bool
  /// The `/` completions for the draft.
  @State private var slash: SlashController
  #if os(macOS)
    @State private var placesOpen: Bool
    @State private var choosingFolder = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.floatsPalettes) private var floatsPalettes
  #endif
  /// How far Dynamic Type has grown the draft text; the send button follows it like the field does.
  @ScaledMetric(relativeTo: .callout) private var growth: CGFloat = 1
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif

  /// The words over the field.
  static let headline = "Let's get started"

  /// `placesOpen` shows the place palette from the start (the Mac; for snapshots).
  init(model: WorkspaceModel, placesOpen: Bool = false) {
    self.model = model
    _slash = State(initialValue: SlashController(workspace: model, target: .draft))
    #if os(macOS)
      _placesOpen = State(initialValue: placesOpen)
    #endif
  }

  private var draft: NewThreadDraft { model.newThreadDraft }

  var body: some View {
    let draft = self.draft
    VStack(spacing: 0) {
      if let notice {
        HostNotice(message: notice)
        if notice.kind != .reconnecting { Hairline() }
      }
      Spacer(minLength: 0)
      composer(draft)
        .padding(.horizontal, LLA.Metrics.margin)
        .padding(.bottom, compact ? LLA.Space.s : 0)
        .frame(maxWidth: LLA.Metrics.column)
      if !compact { Spacer(minLength: 0) }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(LLA.Color.bg)
    .slashCompletionsHost()
    #if os(macOS)
      .blur(radius: placesOpen ? 8 : 0)
      // Under the palette the composer takes no keys (Tab cannot reach it) and is not read out.
      .disabled(placesOpen)
      .accessibilityHidden(placesOpen)
      .overlay { if placesOpen { places(draft) } }
      // In the app the palette itself is in a panel over the veil, so a short window does not cut it.
      .background(
        FloatingPanel(
          isPresented: placesOpen && floatsPalettes,
          size: CGSize(width: PlacePaletteView.width, height: PlacePaletteView.fullHeight),
          placement: .centered, cornerRadius: PlacePaletteView.radius,
          dismissesOnResign: !choosingFolder, dismiss: { closePlaces() }
        ) {
          PlacePaletteView(
            model: model, draft: draft, close: closePlaces, chooseFolder: { choosingFolder = true })
        }
      )
      .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: placesOpen)
      // Search opens over this view: the palette gives way and leaves the focus to it.
      .onChange(of: model.showSearch) { _, shown in if shown { placesOpen = false } }
      .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
        guard case .success(let url) = result else { return }
        draft.chooseFolder(NewThreadDraft.folderPath(of: url))
        focused = true
      }
    #endif
    .navigationTitle("New thread")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    // The draft may have been made before the environments and connections loaded, or its choice may have
    // gone away since: keep what is still offered and fill in the rest.
    .onAppear {
      draft.refreshChoices()
      focused = true
    }
    .onChange(of: model.environments) { draft.refreshChoices() }
    .onChange(of: model.connections) { draft.refreshChoices() }
    // ⌘N, the top bar's New thread, or "New thread here": an open palette gives way to the composer.
    .onChange(of: model.newThreadFocusRequest) {
      #if os(macOS)
        // The palette's dismissal asks for focus as it closes; the folder panel it opened keeps it
        // until the importer answers.
        if choosingFolder { return }
        placesOpen = false
      #endif
      focused = true
    }
    #if os(macOS)
      // The "Choose folder…" command: the panel is the picker row's own, so the places list gives way.
      // No `initial: true`, on purpose: a view made after an old request must not open the panel.
      .onChange(of: model.chooseFolderRequest) {
        placesOpen = false
        choosingFolder = true
      }
    #endif
    // A start accepted later (a retry, a lookup) did not open its thread; open it now.
    .onChange(of: draft.finished) { _, finished in
      guard finished else { return }
      #if os(macOS)
        placesOpen = false
      #endif
      Task { await draft.openStartedThread() }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("new-thread")
  }

  #if os(macOS)
    /// The veil (the window colour at 60% over the blurred view; a click on it closes) and the palette
    /// centred on it, rising in and leaving faster.
    private func places(_ draft: NewThreadDraft) -> some View {
      ZStack {
        LLA.Color.bg.opacity(0.6)
          .contentShape(Rectangle())
          .onTapGesture { closePlaces() }
          .accessibilityHidden(true)
          .transition(reduceMotion ? .identity : .opacity)
        if !floatsPalettes {
          PlacePaletteView(
            model: model, draft: draft, close: closePlaces, chooseFolder: { choosingFolder = true }
          )
          // Its top stays put while the filter shortens the list.
          .frame(height: PlacePaletteView.fullHeight, alignment: .top)
          .transition(
            reduceMotion
              ? .identity
              : .asymmetric(
                insertion: .opacity.combined(with: .offset(y: 10)).combined(with: .scale(scale: 0.98))
                  .animation(.easeOut(duration: 0.2)),
                removal: .opacity.animation(.easeIn(duration: 0.12))))
        }
      }
    }

    private func closePlaces() {
      placesOpen = false
      focused = true
    }
  #endif

  private var compact: Bool {
    #if os(iOS)
      sizeClass == .compact
    #else
      false
    #endif
  }

  /// The phone's notice about the Mac that owns the environment: offline, left the hub, or reconnecting.
  private var notice: HostNoticeMessage? { draft.environment.flatMap(model.startNotice(for:)) }

  /// No text here is `fixedSize(vertical:)`: the split view measures this column at zero width, where a
  /// fixed-height wrapped line grows one character per line, and that minimum made the split view
  /// taller than the window (D-047). The texts still wrap whenever there is room.
  private func composer(_ draft: NewThreadDraft) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(Self.headline)
        .llaDisplay()
        .multilineTextAlignment(compact ? .leading : .center)
        .frame(maxWidth: .infinity, alignment: compact ? .leading : .center)
        .padding(.horizontal, LLA.Space.xs)
        .padding(.bottom, LLA.Space.l)
      ComposerField(
        text: Bindable(draft).text, placeholder: placeholder(draft), focused: $focused,
        onSlashKey: { slash.handle($0, text: Bindable(draft).text) { chooseSlash(draft) } },
        onReturn: { if draft.canSend { Task { await draft.send() } } }
      ) {
        send(draft)
      }
      // Below the field, over the picker row, so the headline above never moves.
      .slashCompletions(slash, placement: .below) { chooseSlash(draft) }
      .onChange(of: draft.text) { old, new in slash.textChanged(from: old, to: new) }
      if model.denseComposer {
        denseLines(draft)
      } else {
        ComposerPickerRow(model: model, .draft(draft), openPlaces: openPlaces)
          .padding(.top, LLA.Space.s)
        statusLine(draft)
      }
    }
  }

  /// Dense, on the Mac: one line where the picker row is. "Starting…" takes its row while it runs; a
  /// failed start sits under the line, which stays so the place can be changed to fix it. Why Send is
  /// off is about the place, so it goes under the line too, unless a failure is showing.
  @ViewBuilder private func denseLines(_ draft: NewThreadDraft) -> some View {
    let failure = draft.status != nil && !draft.submitting && draft.statusIsFailure
    if draft.status != nil, !failure {
      statusLine(draft)
    } else {
      ComposerSummaryLine(summary: .draft(draft, in: model))
        .padding(.top, LLA.Space.s)
      if failure {
        statusLine(draft)
      } else if let reason = draft.blockedReason, notice == nil {
        reasonLine(reason)
      }
    }
  }

  private func openPlaces() {
    #if os(macOS)
      placesOpen = true
    #endif
  }

  /// "Message Claude Code": the chosen connection's label, or plain "Message".
  private func placeholder(_ draft: NewThreadDraft) -> String {
    draft.connection.map { "Message \($0.label)" } ?? "Message"
  }

  private func chooseSlash(_ draft: NewThreadDraft) {
    Task {
      switch await slash.choose() {
      case .text(let text): draft.text = text
      case .send(let text):
        // A runtime command is the new thread's first message, when the draft can start one.
        draft.text = text
        if draft.canSend { await draft.send() } else { draft.text = text + " " }
      case nil: break
      }
    }
  }

  @ViewBuilder private func send(_ draft: NewThreadDraft) -> some View {
    let scale = ComposerField<EmptyView>.scale(growth)
    let style = ComposerCircleStyle(
      diameter: ComposerField<EmptyView>.control * scale, glyph: (slash.isShowing ? 13 : 15) * scale)
    if slash.isShowing {
      // While completions show, Return picks one: a typed slash never starts a thread.
      Button(slash.selected?.primary ?? "Choose", systemImage: "return") { chooseSlash(draft) }
        .buttonStyle(style)
        .disabled(slash.selected?.isAvailable != true)
        .accessibilityIdentifier("slash-choose")
    } else {
      Button("Send", systemImage: "arrow.up") { Task { await draft.send() } }
        .buttonStyle(style)
        .disabled(!draft.canSend)
        .accessibilityIdentifier("send")
    }
  }

  /// "Starting…" or why the start did not go through; otherwise why Send is off, unless the notice
  /// above already says it.
  @ViewBuilder private func statusLine(_ draft: NewThreadDraft) -> some View {
    if let status = draft.status {
      HStack(spacing: LLA.Space.s) {
        if draft.submitting { ProgressView().controlSize(.mini).accessibilityHidden(true) }
        Text(status)
          .font(LLAFont.caption)
          .foregroundStyle(draft.statusIsFailure ? LLA.Color.danger : LLA.Color.muted)
      }
      .padding(.horizontal, ComposerField<EmptyView>.textLeading)
      .padding(.top, LLA.Space.s)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("new-thread-status")
    } else if let reason = draft.blockedReason, notice == nil {
      reasonLine(reason)
    }
  }

  private func reasonLine(_ reason: String) -> some View {
    Text(reason)
      .llaCaption()
      .padding(.horizontal, ComposerField<EmptyView>.textLeading)
      .padding(.top, LLA.Space.s)
      .accessibilityIdentifier("new-thread-reason")
  }
}
