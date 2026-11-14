import SwiftUI
import WorkspaceProtocol

/// Draft text, Send, and Stop. One active turn per thread; the draft is kept locally, never queued
/// into the provider (spec 3.3). The field itself is `ComposerField` (D-061); this view puts a thread's
/// banners, relay lines, and turn row around it and supplies send or stop as its trailing control.
struct ComposerView: View {
  @Bindable var model: WorkspaceModel
  let detail: ThreadDetail
  @FocusState private var focused: Bool
  /// The `/` completions for this thread.
  @State private var slash: SlashController
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// How far Dynamic Type has grown the draft text; the button follows it like the field does.
  @ScaledMetric(relativeTo: .callout) private var growth: CGFloat = 1

  init(model: WorkspaceModel, detail: ThreadDetail) {
    self.model = model
    self.detail = detail
    _slash = State(initialValue: SlashController(workspace: model, target: .thread(detail.thread.id)))
  }

  private var activeTurn: Turn? { detail.activeTurn }
  private var canSend: Bool {
    activeTurn == nil && !model.busy && detail.thread.continuity == .available
      && model.sendBlockedReason(for: detail.thread) == nil
      && !model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// The phone's Mac is offline or left the hub: the field is off, and its notice is the reason.
  private var unreachable: String? { model.controlsDisabledReason(for: detail.thread) }

  var body: some View {
    VStack(alignment: .leading, spacing: LLA.Space.s) {
      if let error = model.lastError,
        !Remediation.coveredByContinuity(model.lastFailure, continuity: detail.thread.continuity)
      {
        ThreadErrorNotice(error: error, failure: model.lastFailure, remedy: model.remediation) { action in
          Task { await model.perform(action) }
        } dismiss: {
          model.lastError = nil
        }
      }
      relayLines
      if let turn = activeTurn { turnRow(turn) }
      ComposerField(
        text: $model.composerText, placeholder: placeholder, focused: $focused,
        onSlashKey: { slash.handle($0, text: $model.composerText) { chooseSlash() } },
        onReturn: { if canSend { send() } }
      ) {
        sendOrStop
      }
      .slashCompletions(slash, placement: .above) { chooseSlash() }
      .disabled(unreachable != nil)
      // Where the thread runs, and the permission and model its next turn uses; at dense, on the Mac,
      // one line naming the runtime and permission.
      if model.denseComposer {
        ComposerSummaryLine(summary: .thread(detail.thread, in: model))
      } else {
        ComposerPickerRow(model: model, .thread(detail.thread))
      }
    }
    .padding(.horizontal, LLA.Metrics.margin)
    .padding(.top, LLA.Space.s)
    .padding(.bottom, Self.bottomPadding)
    .frame(maxWidth: LLA.Metrics.column)
    .frame(maxWidth: .infinity)
    .onChange(of: model.composerText) { old, new in slash.textChanged(from: old, to: new) }
    .onChange(of: detail.thread.id, initial: true) { _, id in slash.target = .thread(id) }
    // The palette closed, or a command finished: writing resumes where it was.
    .task(id: model.composerFocusRequest) {
      // Also on appearing: the request may be older than this view (the palette opened this thread).
      guard model.answeredComposerFocusRequest != model.composerFocusRequest else { return }
      model.answeredComposerFocusRequest = model.composerFocusRequest
      // The field may not take the cursor yet: it is still being laid out, or the closing palette's
      // field still has it. Ask until it does, for a third of a second at most.
      for _ in 0..<7 where !focused {
        focused = true
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
  }

  /// Pick the selected completion; a pick may clear the token from the draft or put the slash back.
  private func chooseSlash() {
    Task {
      switch await slash.choose() {
      case .text(let text): model.composerText = text
      case .send(let text):
        // A runtime command is a message. While a turn runs it waits in the draft, never a stop.
        model.composerText = text
        if canSend { await model.send() } else { model.composerText = text + " " }
      case nil: break
      }
    }
  }

  // MARK: Metrics

  static let line = ComposerField<EmptyView>.line
  static let control = ComposerField<EmptyView>.control
  static let textLeading = ComposerField<EmptyView>.textLeading

  private var scale: CGFloat { ComposerField<EmptyView>.scale(growth) }
  private var controlSize: CGFloat { Self.control * scale }

  #if os(iOS)
    private static let bottomPadding = LLA.Space.s
  #else
    private static let bottomPadding = LLA.Space.l
  #endif

  /// "Message Codex": the connection's label, or plain "Message". On the phone, why it cannot send
  /// instead while its Mac is offline (the field is then off).
  private var placeholder: String {
    if let reason = unreachable { return reason }
    return model.connection(id: detail.thread.connectionId).map { "Message \($0.label)" } ?? "Message"
  }

  // MARK: Send and stop

  /// Send, or Stop while a turn runs: one round button in the same place, as in ChatGPT.
  @ViewBuilder private var sendOrStop: some View {
    if slash.isShowing {
      // While completions show, Return picks one: a typed slash is never sent, and never stops a turn.
      Button(slash.selected?.primary ?? "Choose", systemImage: "return") { chooseSlash() }
        .buttonStyle(ComposerCircleStyle(diameter: controlSize, glyph: 13 * scale))
        .disabled(slash.selected?.isAvailable != true)
        .accessibilityIdentifier("slash-choose")
    } else if let turn = activeTurn {
      Button("Stop", systemImage: "stop.fill") { Task { await model.stop() } }
        .buttonStyle(ComposerCircleStyle(diameter: controlSize, glyph: 11 * scale))
        .disabled(
          turn.nativeTurnId == nil || turn.status == .stopping || turn.status == .reconciling
            || !model.canStop(detail.thread)
        )
        .accessibilityIdentifier("stop")
    } else {
      Button("Send", systemImage: "arrow.up", action: send)
        .buttonStyle(ComposerCircleStyle(diameter: controlSize, glyph: 15 * scale))
        .disabled(!canSend)
        .accessibilityIdentifier("send")
    }
  }

  private func send() { Task { await model.send() } }

  // MARK: Above the field

  /// The line above the field while a turn holds the draft, in the thread header's words.
  static func turnNote(for status: TurnStatus) -> String {
    let state =
      switch status {
      case .submitting: "A turn is being sent."
      case .running: "A turn is running."
      case .waitingForUser: "The turn is waiting for you."
      case .stopping: "A turn is stopping."
      case .reconciling: "A turn's outcome is unknown."
      case .terminal: "A turn is finishing."
      }
    return state + " Your draft stays here until it finishes."
  }

  /// What the running turn means for the draft, and the reconcile pair when its outcome is unknown.
  /// The words line up with the text inside the field.
  private func turnRow(_ turn: Turn) -> some View {
    // Two lines at most on the Mac, whose smallest window must still fit the detail
    // (`DetailMinimumSizeTests`); the phone wraps it whole, for large text.
    let words =
      model.activeTurnLabel(for: detail.thread) ?? Self.turnNote(for: turn.status)
    let text = Text(words)
      .llaCaption()
      #if os(macOS)
        .lineLimit(2)
      #else
        .fixedSize(horizontal: false, vertical: true)
      #endif
    return Group {
      if turn.status == .reconciling {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: LLA.Space.s) {
            text
            Spacer(minLength: LLA.Space.s)
            reconcileButtons
          }
          VStack(alignment: .leading, spacing: LLA.Space.s) {
            text
            HStack(spacing: LLA.Space.s) { reconcileButtons }
          }
        }
      } else {
        text
      }
    }
    .padding(.horizontal, Self.textLeading)
  }

  @ViewBuilder private var reconcileButtons: some View {
    Button("Check again") { Task { await model.reconcileThread(id: detail.thread.id) } }
      .buttonStyle(.llaSecondary)
      .disabled(model.busy)
      .accessibilityIdentifier("check-again")
    Button("Abandon turn", role: .destructive) {
      Task { await model.abandonTurn(threadId: detail.thread.id) }
    }
    .buttonStyle(.llaDanger)
    .disabled(model.busy)
    .help("Give up on this turn's unknown outcome so the thread can take a new message. Nothing is re-sent.")
    .accessibilityIdentifier("abandon")
  }

  /// The phone's relay, in one caption line each: Stop waiting for the Mac or not confirmed, and a
  /// refused send's reason in place of its message (which the transcript no longer shows).
  @ViewBuilder private var relayLines: some View {
    // Visible whether or not there is a draft, while the phone's own link is down.
    if let connecting = model.hubLinkNotice {
      relayLine(connecting, danger: false, waiting: true).accessibilityIdentifier("hub-link")
    }
    if let stop = model.stopStates[detail.thread.id] {
      relayLine(stop.label, danger: stop != .waiting, waiting: stop == .waiting)
        .accessibilityIdentifier("stop-state")
    }
    if case .refused? = model.pendingSends[detail.thread.id]?.state,
      let reason = model.sendStatus(for: detail.thread.id)
    {
      relayLine(reason, danger: true, waiting: false).accessibilityIdentifier("send-refused")
    }
  }

  private func relayLine(_ text: String, danger: Bool, waiting: Bool) -> some View {
    HStack(spacing: LLA.Space.s) {
      if waiting { ProgressView().controlSize(.mini).accessibilityHidden(true) }
      Text(text)
        .font(LLAFont.caption)
        .foregroundStyle(danger ? LLA.Color.danger : LLA.Color.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
    // The phone already gets its page gutter from ComposerView; do not add it a second time.
    #if os(macOS)
      .padding(.horizontal, Self.textLeading)
    #endif
    .accessibilityElement(children: .combine)
  }

}

/// The composer's round button: an ink circle (32 pt at the default text size) with the symbol in the
/// background colour, and a target 12 pt larger (44 pt). Disabled, it recedes to a raised-surface circle with a ghost symbol rather than a
/// faded ink one, so it reads as unavailable, not pressed.
struct ComposerCircleStyle: ButtonStyle {
  let diameter: CGFloat
  /// The symbol's point size: 15 for the arrow, 11 for the stop square, which reads larger.
  let glyph: CGFloat
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    Self.face(configuration.label, diameter: diameter, glyph: glyph, enabled: isEnabled)
      .opacity(configuration.isPressed ? 0.75 : 1)
      .contentShape(Circle().inset(by: -(ComposerView.line - ComposerView.control) / 2))
  }

  /// The circle alone, for a field that only looks like the composer (the iPhone list's "New thread").
  static func face(_ label: some View, diameter: CGFloat, glyph: CGFloat, enabled: Bool) -> some View {
    label
      .labelStyle(.iconOnly)
      .font(.system(size: glyph, weight: .bold))
      .foregroundStyle(enabled ? LLA.Color.bg : LLA.Color.ghost)
      .frame(width: diameter, height: diameter)
      .background(Circle().fill(enabled ? LLA.Color.ink : LLA.Color.surfaceRaised))
  }
}
