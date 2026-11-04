import SwiftUI
import WorkspaceProtocol

/// Draft text, Send, and Stop. One active turn per thread; the draft is kept locally, never queued
/// into the provider (spec 3.3). The field itself is `ComposerField` (D-061); this view puts a thread's
/// banners, relay lines, and turn row around it and supplies send or stop as its trailing control.
struct ComposerView: View {
  @Bindable var model: WorkspaceModel
  let detail: ThreadDetail
  @FocusState private var focused: Bool
  /// How far Dynamic Type has grown the draft text; the button follows it like the field does.
  @ScaledMetric(relativeTo: .callout) private var growth: CGFloat = 1

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
      if let error = model.lastError { errorBanner(error) }
      relayLines
      if let turn = activeTurn { turnRow(turn) }
      ComposerField(text: $model.composerText, placeholder: placeholder, focused: $focused) {
        sendOrStop
      }
      .disabled(unreachable != nil)
    }
    .padding(.horizontal, LLA.Metrics.margin)
    .padding(.top, LLA.Space.s)
    .padding(.bottom, Self.bottomPadding)
    .frame(maxWidth: LLA.Metrics.column)
    .frame(maxWidth: .infinity)
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
    if let turn = activeTurn {
      Button("Stop", systemImage: "stop.fill") { Task { await model.stop() } }
        .buttonStyle(ComposerCircleStyle(diameter: controlSize, glyph: 11 * scale))
        .disabled(
          turn.nativeTurnId == nil || turn.status == .stopping || turn.status == .reconciling
            || !model.canStop(detail.thread)
        )
        .accessibilityIdentifier("stop")
    } else {
      Button("Send", systemImage: "arrow.up") { Task { await model.send() } }
        .keyboardShortcut(.return, modifiers: [])
        .buttonStyle(ComposerCircleStyle(diameter: controlSize, glyph: 15 * scale))
        .disabled(!canSend)
        .accessibilityIdentifier("send")
    }
  }

  // MARK: Above the field

  /// What the running turn means for the draft, and the reconcile pair when its outcome is unknown.
  /// The words line up with the text inside the field.
  private func turnRow(_ turn: Turn) -> some View {
    // Two lines at most on the Mac, whose smallest window must still fit the detail
    // (`DetailMinimumSizeTests`); the phone wraps it whole, for large text.
    let words =
      model.activeTurnLabel(for: detail.thread)
      ?? "A turn is \(turn.status.rawValue). Your draft stays here until it finishes."
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
    .padding(.horizontal, Self.textLeading)
    .accessibilityElement(children: .combine)
  }

  private func errorBanner(_ error: String) -> some View {
    let remedy = model.remediation
    return LLACard(fill: .surface, padding: LLA.Space.m) {
      HStack(alignment: .top, spacing: LLA.Space.m) {
        VStack(alignment: .leading, spacing: 2) {
          Text(remedy?.message ?? error).font(LLAFont.small).foregroundStyle(LLA.Color.danger)
          if remedy != nil, let code = model.lastFailure?.code {
            Text(code.rawValue).llaCodeMuted()
          }
        }
        Spacer()
        if let remedy, let title = remedy.actionTitle, remedy.action != .none {
          Button(title) { Task { await model.perform(remedy.action) } }
            .buttonStyle(.llaSecondary)
            .accessibilityIdentifier("remediation")
        }
        Button("Dismiss") { model.lastError = nil }.buttonStyle(.llaLink)
      }
    }
    .accessibilityIdentifier("error-banner")
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
    configuration.label
      .labelStyle(.iconOnly)
      .font(.system(size: glyph, weight: .bold))
      .foregroundStyle(isEnabled ? LLA.Color.bg : LLA.Color.ghost)
      .frame(width: diameter, height: diameter)
      .background(Circle().fill(isEnabled ? LLA.Color.ink : LLA.Color.surfaceRaised))
      .opacity(configuration.isPressed ? 0.75 : 1)
      .contentShape(Circle().inset(by: -(ComposerView.line - ComposerView.control) / 2))
  }
}
