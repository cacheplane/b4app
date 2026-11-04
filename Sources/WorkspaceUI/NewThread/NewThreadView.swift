import SwiftUI
import WorkspaceProtocol

/// A new thread from a blank composer (the new-thread composer spec, "The Mac" and "The iPhone"): a
/// headline, the field, the picker row under it, and the draft's start status. Nothing exists until
/// Send, which creates the thread, starts its first turn, and opens it. The draft is the device's one
/// `newThreadDraft`, so its text and choices outlive this screen.
///
/// The Mac (and any regular width) centres the headline and the field in the reading column; a
/// compact width pins the field and the row to the bottom, above the keyboard, under the "New thread"
/// title.
struct NewThreadView: View {
  @Bindable var model: WorkspaceModel
  @FocusState private var focused: Bool
  /// How far Dynamic Type has grown the draft text; the send button follows it like the field does.
  @ScaledMetric(relativeTo: .callout) private var growth: CGFloat = 1
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif

  /// The words over the field.
  static let headline = "What should we work on?"

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
    .navigationTitle("New thread")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    // The draft may have been made before the projects and connections loaded, or its choice may have
    // gone away since: keep what is still offered and fill in the rest.
    .onAppear {
      draft.refreshChoices()
      focused = true
    }
    .onChange(of: model.projects) { draft.refreshChoices() }
    .onChange(of: model.connections) { draft.refreshChoices() }
    .onChange(of: model.newThreadFocusRequest) { focused = true }
    // A start accepted later (a retry, a lookup) did not open its thread; open it now.
    .onChange(of: draft.finished) { _, finished in
      if finished { Task { await draft.openStartedThread() } }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("new-thread")
  }

  private var compact: Bool {
    #if os(iOS)
      sizeClass == .compact
    #else
      false
    #endif
  }

  /// The phone's notice about the Mac that owns the project: offline, left the hub, or reconnecting.
  private var notice: HostNoticeMessage? { draft.project.flatMap(model.startNotice(for:)) }

  private func composer(_ draft: NewThreadDraft) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(Self.headline)
        .llaDisplay()
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, LLA.Space.xs)
        .padding(.bottom, LLA.Space.l)
      ComposerField(text: Bindable(draft).text, placeholder: placeholder(draft), focused: $focused) {
        send(draft)
      }
      ComposerPickerRow(model: model, .draft(draft))
        .padding(.top, LLA.Space.s)
      statusLine(draft)
    }
  }

  /// "Message Claude Code": the chosen connection's label, or plain "Message".
  private func placeholder(_ draft: NewThreadDraft) -> String {
    draft.connection.map { "Message \($0.label)" } ?? "Message"
  }

  private func send(_ draft: NewThreadDraft) -> some View {
    let scale = ComposerField<EmptyView>.scale(growth)
    return Button("Send", systemImage: "arrow.up") { Task { await draft.send() } }
      .keyboardShortcut(.return, modifiers: [])
      .buttonStyle(
        ComposerCircleStyle(diameter: ComposerField<EmptyView>.control * scale, glyph: 15 * scale)
      )
      .disabled(!draft.canSend)
      .accessibilityIdentifier("send")
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
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, ComposerField<EmptyView>.textLeading)
      .padding(.top, LLA.Space.s)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("new-thread-status")
    } else if let reason = draft.blockedReason, notice == nil {
      Text(reason)
        .llaCaption()
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, ComposerField<EmptyView>.textLeading)
        .padding(.top, LLA.Space.s)
        .accessibilityIdentifier("new-thread-reason")
    }
  }
}
