import SwiftUI
import WorkspaceProtocol

/// Draft text, Send, and Stop. One active turn per thread; the draft is kept locally, never queued
/// into the provider (spec 3.3).
///
/// D-061: one rounded field in two shapes. The box (every iPhone, and any wider screen once the draft
/// wraps) has the text on top and a tool row underneath, send at its trailing end. The line (iPad and
/// Mac while the draft fits) is a 44 pt capsule with send inline. The text grows to three lines, then
/// scrolls. Attachments, when a turn can carry them, go in a row between the text and the tool row,
/// with attach at the tool row's leading end; neither is drawn until then.
struct ComposerView: View {
  @Bindable var model: WorkspaceModel
  let detail: ThreadDetail
  @Environment(\.dynamicTypeSize) private var typeSize
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif
  /// One line of draft text, measured, so the box's first line sits where the line's text sits.
  @State private var lineHeight: CGFloat = 20
  /// The draft's natural one-line width and the field's own width, for choosing the shape.
  @State private var draftWidth: CGFloat = 0
  @State private var fieldWidth: CGFloat = 0
  #if os(macOS)
    @State private var editorHeight: CGFloat = 20
  #endif
  /// How far Dynamic Type has grown the draft text; the line and the button follow it up to 1.5 times,
  /// so the button stays a meaningful size beside large text without crowding the field.
  @ScaledMetric(relativeTo: .callout) private var growth: CGFloat = 1

  private var activeTurn: Turn? { detail.activeTurn }
  private var canSend: Bool {
    activeTurn == nil && !model.busy && detail.thread.continuity == .available
      && !model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: LLA.Space.s) {
      if let error = model.lastError { errorBanner(error) }
      if let turn = activeTurn { turnRow(turn) }
      field
    }
    .padding(.horizontal, LLA.Metrics.margin)
    .padding(.top, LLA.Space.s)
    .padding(.bottom, Self.bottomPadding)
    .frame(maxWidth: LLA.Metrics.column)
    .frame(maxWidth: .infinity)
  }

  // MARK: Metrics

  /// The line's height and the send button's diameter at the default text size. The button sits
  /// `inset` from the field's edge on every side it touches, so its circle is concentric with the
  /// field's corner.
  static let line: CGFloat = 44
  static let control: CGFloat = 32
  static let inset: CGFloat = (line - control) / 2

  private var scale: CGFloat { min(max(growth, 1), 1.5) }
  private var lineSize: CGFloat { Self.line * scale }
  private var controlSize: CGFloat { Self.control * scale }
  private var insetSize: CGFloat { Self.inset * scale }
  /// Text starts 16 pt in from the field's edge in both shapes.
  static let textLeading: CGFloat = 16
  /// Between the last line of text and the tool row in the box.
  static let toolGap: CGFloat = 4

  #if os(iOS)
    private static let bottomPadding = LLA.Space.s
  #else
    private static let bottomPadding = LLA.Space.l
  #endif

  /// Where the first line of text starts in both shapes: centred in a 44 pt line.
  private var textTop: CGFloat { max((lineSize - lineHeight) / 2, insetSize) }

  enum Shape { case line, box }

  private var shape: Shape {
    #if os(iOS)
      let wide = sizeClass == .regular
    #else
      let wide = true
    #endif
    return Self.shape(
      wide: wide, accessibilitySize: typeSize.isAccessibilitySize, draft: model.composerText,
      draftWidth: draftWidth, fieldWidth: fieldWidth, control: controlSize, inset: insetSize)
  }

  /// The line only where the screen is wide, the text is not at an accessibility size, and the draft
  /// has no line break and fits on one line beside the button; the box otherwise. Before the field
  /// has a width, a wide screen starts with the line.
  static func shape(
    wide: Bool, accessibilitySize: Bool, draft: String, draftWidth: CGFloat, fieldWidth: CGFloat,
    control: CGFloat = control, inset: CGFloat = inset
  ) -> Shape {
    guard wide, !accessibilitySize, !draft.contains("\n") else { return .box }
    let room = fieldWidth - textLeading - LLA.Space.s - control - inset
    return fieldWidth == 0 || draftWidth <= room ? .line : .box
  }

  // MARK: The field

  private var field: some View {
    let shape = self.shape
    let layout =
      shape == .line
      ? AnyLayout(HStackLayout(alignment: .center, spacing: LLA.Space.s))
      : AnyLayout(VStackLayout(alignment: .leading, spacing: Self.toolGap))
    // One layout whose children keep their identity across both shapes, so the text keeps focus and
    // the caret when the field changes shape under it.
    return layout {
      editor
        .padding(.leading, Self.textLeading - insetSize)
        .padding(.trailing, shape == .line ? 0 : Self.textLeading - insetSize)
        .padding(.top, shape == .line ? 0 : textTop - insetSize)
      HStack(spacing: LLA.Space.s) {
        if shape == .box { Spacer(minLength: 0) }
        sendOrStop
      }
    }
    .padding(insetSize)
    .frame(minHeight: lineSize)
    // Circular corners, not continuous: a continuous corner at half the height flattens the line's
    // ends, and only a circular arc is concentric with the round button inside it.
    .background(
      RoundedRectangle(cornerRadius: lineSize / 2, style: .circular).fill(LLA.Color.surface)
    )
    .overlay(
      RoundedRectangle(cornerRadius: lineSize / 2, style: .circular).strokeBorder(LLA.Color.rule)
    )
    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { fieldWidth = $0 }
    .background(alignment: .topLeading) { measurements }
  }

  /// Hidden copies of one line and of the draft on one line, in the field's font.
  private var measurements: some View {
    ZStack(alignment: .topLeading) {
      Text("Ag").font(LLAFont.composer)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { lineHeight = $0 }
      Text(model.composerText.isEmpty ? placeholder : model.composerText)
        .font(LLAFont.composer).lineLimit(1).fixedSize()
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { draftWidth = $0 }
    }
    .hidden()
    .accessibilityHidden(true)
  }

  #if os(iOS)
    /// A vertical text field: it grows a line at a time to three, then scrolls, with no inner inset,
    /// so its text sits exactly at the padding above. Return adds a line; the button sends.
    private var editor: some View {
      TextField(
        "", text: $model.composerText,
        prompt: Text(placeholder).foregroundStyle(LLA.Color.muted), axis: .vertical
      )
      .textFieldStyle(.plain)
      .font(LLAFont.composer)
      .foregroundStyle(LLA.Color.ink)
      .lineLimit(1...3)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityLabel(placeholder)
      .accessibilityIdentifier("composer")
    }
  #else
    /// The Mac keeps `TextEditor`, whose Return the Send button's shortcut takes and whose Shift-Return
    /// adds a line. A hidden copy of the draft sets its height, one line to three. The editor indents
    /// its text 5 pt (its line fragment padding), which the copy and the placeholder match.
    private var editor: some View {
      ZStack(alignment: .topLeading) {
        Text(model.composerText.isEmpty ? " " : model.composerText + " ")
          .font(LLAFont.composer)
          .padding(.horizontal, 5)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
          .hidden()
          .accessibilityHidden(true)
          .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { editorHeight = $0 }
        if model.composerText.isEmpty {
          Text(placeholder)
            .font(LLAFont.composer)
            .foregroundStyle(LLA.Color.muted)
            .padding(.horizontal, 5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        TextEditor(text: $model.composerText)
          .font(LLAFont.composer)
          .foregroundStyle(LLA.Color.ink)
          .scrollContentBackground(.hidden)
          .scrollIndicators(.never)
          .accessibilityLabel(placeholder)
          .accessibilityIdentifier("composer")
      }
      .frame(height: min(max(editorHeight, lineHeight), lineHeight * 3))
      .padding(.leading, -5)
    }
  #endif

  /// "Message Codex": the connection's label, or plain "Message".
  private var placeholder: String {
    model.connection(id: detail.thread.connectionId).map { "Message \($0.label)" } ?? "Message"
  }

  // MARK: Send and stop

  /// Send, or Stop while a turn runs: one round button in the same place, as in ChatGPT.
  @ViewBuilder private var sendOrStop: some View {
    if let turn = activeTurn {
      Button("Stop", systemImage: "stop.fill") { Task { await model.stop() } }
        .buttonStyle(ComposerCircleStyle(diameter: controlSize, glyph: 11 * scale))
        .disabled(turn.nativeTurnId == nil || turn.status == .stopping || turn.status == .reconciling)
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
    let text = Text("A turn is \(turn.status.rawValue). Your draft stays here until it finishes.")
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
