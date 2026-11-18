import SwiftUI
import WorkspaceProtocol

/// Which turns' lines are open, by group key. Owned by the transcript as `@State`, so it is forgotten
/// with the view and never stored.
@Observable final class TranscriptFolds {
  var open: Set<String>
  /// From a toggle until the reader returns to the end, sends a message, or another thread is shown:
  /// the transcript neither pins its bottom edge nor follows the stream, so the opened line stays put.
  private(set) var holds = false

  /// How many of the thread's latest rows are drawn; "Show earlier" adds a page.
  private(set) var shown = DenseTranscript.page
  /// The row that stood first when "Show earlier" was pressed: it is kept at the top of the view as
  /// the earlier rows are drawn above it.
  private(set) var kept: String?

  init(open: Set<String> = []) { self.open = open }

  /// The reader asked for earlier rows: a page more, and the view is theirs until they return to the end.
  func showEarlier(keeping first: String?) {
    kept = first
    shown += DenseTranscript.page
    holds = true
  }

  func toggle(_ group: String) {
    if open.contains(group) { open.remove(group) } else { open.insert(group) }
    holds = true
  }

  /// The reader scrolled back from the end: the same hold as opening a turn, so neither the stream nor
  /// a turn's end moves what they are reading.
  func hold() {
    if !holds { holds = true }
  }

  /// The bottom pin and the following come back.
  func release() {
    if holds { holds = false }
  }

  func reset() {
    if !open.isEmpty { open = [] }
    if shown != DenseTranscript.page { shown = DenseTranscript.page }
    kept = nil
    release()
  }
}

/// The content's height, where the viewport's top edge stands in it, and whether its end is in view
/// (within 8 pt of the viewport's). The height is part of it so a toggle that leaves the content
/// fitting the viewport still reports in.
struct TranscriptEnd: Equatable {
  var height: CGFloat
  var top: CGFloat
  var reached: Bool
  /// The end marker is out of view: more than the transcript's bottom padding lies below the viewport.
  /// Following the stream rests the view with that padding below it, so nearer than this is the end.
  var away: Bool

  init(height: CGFloat, top: CGFloat, reached: Bool, away: Bool) {
    self.height = height
    self.top = top
    self.reached = reached
    self.away = away
  }

  init(_ geometry: ScrollGeometry) {
    height = geometry.contentSize.height
    top = geometry.visibleRect.minY
    let below = geometry.contentSize.height - geometry.visibleRect.maxY
    reached = below <= 8
    away = below > LLA.Metrics.margin + 8
  }

  /// What a change of geometry says about the reader. The end in view: following. The viewport's top
  /// edge moved up over content of the same height, the end marker out of view: the reader went back (a
  /// wheel, a drag, Page Up, the scroller). Content growing under a still viewport, the view being
  /// taken down to the end, and a layout pass that resizes the content and moves the view with it are
  /// none of these: the top edge stays or moves down, or the height changed in the same step.
  enum Intent: Equatable { case following, reading, unchanged }

  static func intent(from old: TranscriptEnd, to new: TranscriptEnd) -> Intent {
    if new.reached { return .following }
    return new.away && new.top < old.top - 0.5 && abs(new.height - old.height) <= 0.5
      ? .reading : .unchanged
  }
}

/// Cached items plus live streaming text. Agent output is rendered as text, never executed.
struct TranscriptView: View {
  let detail: ThreadDetail
  /// The thread's streaming messages. The body never reads their per-token state: only the rows and
  /// the zero-size follower inside the scroll content do.
  let streams: MessageStreamStore
  /// The phone's message still on its way to the Mac, shown after the items with its state, until its
  /// turn's own message arrives (M8c). Always nil on the Mac.
  var pending: PendingSend? = nil
  var pendingStatus: String? = nil
  @State private var folds: TranscriptFolds
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(
    detail: ThreadDetail, streams: MessageStreamStore, pending: PendingSend? = nil,
    pendingStatus: String? = nil, folds: TranscriptFolds = TranscriptFolds()
  ) {
    self.detail = detail
    self.streams = streams
    self.pending = pending
    self.pendingStatus = pendingStatus
    _folds = State(initialValue: folds)
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        TranscriptContent(
          detail: detail, streams: streams, pending: pending, pendingStatus: pendingStatus,
          folds: folds
        )
        .background { StreamFollower(streams: streams) { follow(proxy) } }
      }
      .accessibilityIdentifier("transcript")
      #if os(iOS)
        // Dragging the transcript down puts the keyboard away, as in Messages.
        .scrollDismissesKeyboard(.interactively)
      #endif
      // A thread opens at its latest message. When the content shrinks (a Stop drops a reply's live
      // text, a reload draws fewer rows), keep the bottom edge in place; scrolling to "bottom" in
      // the same update reads the old layout and leaves the view past the new end.
      // While an opened turn holds the view, its top edge is kept instead, so the line the reader
      // pressed stays where it was as its steps are drawn under it and the stream goes on below.
      .defaultScrollAnchor(.bottom, for: .initialOffset)
      .defaultScrollAnchor(folds.holds ? .top : .bottom, for: .sizeChanges)
      .onScrollGeometryChange(for: TranscriptEnd.self, of: TranscriptEnd.init) { old, end in
        switch TranscriptEnd.intent(from: old, to: end) {
        case .following: folds.release()
        case .reading: folds.hold()
        case .unchanged: break
        }
      }
      // While the view is held, the latest content is out of sight below: one press goes back to it
      // and follows the stream again.
      .overlay(alignment: .bottom) {
        if folds.holds {
          Button("Jump to latest") {
            folds.release()
            proxy.scrollTo("bottom", anchor: .bottom)
          }
          .buttonStyle(.llaSecondary)
          // The pill's fill is close to the page's: a rule keeps its edge visible over the transcript.
          .overlay(Capsule().stroke(LLA.Color.rule, lineWidth: 1))
          .llaPopoverShadow()
          .padding(.bottom, LLA.Space.m)
          .accessibilityIdentifier("jump-to-latest")
          .accessibilityHint("Scrolls to the end of the thread and follows new output")
        }
      }
      // Earlier rows were drawn above: the row that stood first stays at the top of the view.
      .onChange(of: folds.shown) { _, _ in
        if let kept = folds.kept { proxy.scrollTo(kept, anchor: .top) }
      }
      // A reply is revealed at a reading pace while the thread is on screen; with Reduce Motion on, or
      // off screen, everything received is shown at once.
      .onAppear { streams.transcriptAppeared(reduceMotion: reduceMotion) }
      .onChange(of: reduceMotion) { _, now in streams.setReduceMotion(now) }
      .onDisappear { streams.transcriptDisappeared() }
      .onChange(of: detail.items.count) { _, _ in follow(proxy) }
      .onChange(of: detail.turns.filter { $0.status == .terminal }.count) { _, _ in follow(proxy) }
      // The reader sent something: back to the end, as today.
      .onChange(of: pending?.id) { _, _ in
        folds.release()
        proxy.scrollTo("bottom", anchor: .bottom)
      }
      .onChange(of: detail.turns.count) { old, new in
        guard new > old, folds.holds else { return }
        folds.release()
        proxy.scrollTo("bottom", anchor: .bottom)
      }
      // The same view shows the next thread. If a turn held this one, a `follow` that ran first in this
      // update saw the hold and did nothing, so the next thread is taken to its end here.
      .onChange(of: detail.thread.id) { _, _ in
        let held = folds.holds
        folds.reset()
        if held { proxy.scrollTo("bottom", anchor: .bottom) }
      }
    }
  }

  /// Keeps the end in view as the thread grows, unless an opened turn or a reader who scrolled back
  /// holds the view.
  private func follow(_ proxy: ScrollViewProxy) {
    guard !folds.holds else { return }
    proxy.scrollTo("bottom", anchor: .bottom)
  }
}

/// Follows a growing reply: a zero-size leaf that alone reads the streams' revision, so a reveal
/// re-evaluates it and not the transcript around it.
private struct StreamFollower: View {
  let streams: MessageStreamStore
  let follow: () -> Void

  var body: some View {
    Color.clear.frame(width: 0, height: 0)
      .accessibilityHidden(true)
      .onChange(of: streams.revision) { _, _ in follow() }
  }
}

/// The transcript's rows, without the scroll view around them (so a test can measure them).
struct TranscriptContent: View {
  let detail: ThreadDetail
  let streams: MessageStreamStore
  var pending: PendingSend? = nil
  var pendingStatus: String? = nil
  let folds: TranscriptFolds
  var body: some View {
    // Not a lazy stack. A lazy stack sizes rows it has not laid out by estimate, and with the bottom
    // edge pinned it kept that estimate: a thread whose first reply was several windows tall opened
    // partway up it with the later messages never laid out, and a short thread could stop following
    // its stream. Every drawn row is laid out, and `DenseTranscript.window` bounds how many there are.
    VStack(alignment: .leading, spacing: LLA.Space.l) { rows }
      .padding(.horizontal, LLA.Metrics.margin)
      .padding(.vertical, LLA.Metrics.margin)
      .frame(maxWidth: LLA.Metrics.column, alignment: .leading)
      .frame(maxWidth: .infinity)
  }

  /// Each turn's work folds into a line, an ended turn's open steps settle, and its note goes with it.
  private var window: DenseTranscript.Window {
    DenseTranscript.window(
      DenseTranscript.entries(items: detail.items, turns: detail.turns, open: folds.open),
      shown: folds.shown)
  }

  @ViewBuilder private var rows: some View {
    if detail.items.isEmpty && pending == nil {
      Text("No messages yet. Say something below.").llaMuted()
    }
    let window = window
    if window.hidden > 0 {
      Button("Show earlier") { folds.showEarlier(keeping: window.entries.first?.id) }
        .buttonStyle(.llaLink)
        .frame(maxWidth: .infinity, minHeight: LLA.Metrics.row)
        .accessibilityLabel("Show earlier, \(window.hidden) more")
        .accessibilityIdentifier("show-earlier")
    }
    // A line and the step rows under it are one child of the column, so they stand close.
    ForEach(DenseTranscript.runs(window.entries), id: \.first?.id) { run in
      VStack(alignment: .leading, spacing: 0) {
        ForEach(run) { entry in self.entry(entry) }
      }
    }
    if let pending {
      PendingMessageRow(send: pending, status: pendingStatus).id("pending-\(pending.id)")
    }
    if let turn = detail.activeTurn, turn.status == .reconciling {
      HStack(alignment: .top, spacing: LLA.Space.s) {
        LLAStateDot(state: .unknown).padding(.top, 2)
        Text(
          "The runtime stopped before this turn finished. Its outcome is unknown; check again below, or abandon the turn to continue."
        )
        .llaSmall().fixedSize(horizontal: false, vertical: true)
      }
    }
    Color.clear.frame(height: 1).id("bottom")
  }

  @ViewBuilder private func entry(_ entry: DenseTranscript.Entry) -> some View {
    switch entry {
    case .item(let item):
      TranscriptRow(item: item, streams: streams)
        .id(item.id)
    case .line(let line):
      ActivityLineRow(line: line, open: folds.open.contains(line.group)) {
        folds.toggle(line.group)
      }
      .id(entry.id)
    case .step(let row):
      StepRowView(row: row, streams: streams, open: folds.open.contains(row.id)) {
        folds.toggle(row.id)
      }
      .id(entry.id)
    case .note(let turn):
      TurnNoteRow(turn: turn).id(entry.id)
    }
  }
}

/// A turn's line: the working mark while it runs, what the turn did or is doing, the time it took or
/// has taken, and the word that shows or hides its work. One muted line, cut at its tail; at
/// accessibility sizes it stacks. A line with nothing to open is read as its words and is not a control.
struct ActivityLineRow: View {
  let line: DenseTranscript.ActivityLine
  let open: Bool
  let toggle: () -> Void
  @Environment(\.dynamicTypeSize) private var typeSize

  /// The line read as one element: "4 steps, 1 failed, 1m 12s, Show".
  var label: String { line.spoken(open: open) }

  /// Whether the row draws a clock: only a line that has not ended does, and it is the only part of the
  /// row that reads the time.
  static func ticks(_ line: DenseTranscript.ActivityLine) -> Bool { line.startedAt != nil }

  var body: some View {
    Group {
      if line.canOpen {
        Button {
          withAnimation(.none) { toggle() }
        } label: {
          content
        }
        .buttonStyle(.plain)
      } else {
        content
      }
    }
    // The row's children are its words and its clock, so the clock speaks the time it shows: nothing
    // outside the clock's `TimelineView` reads it.
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("activity-line")
  }

  private var content: some View {
    let stacked = typeSize.isAccessibilitySize
    let layout =
      stacked
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: LLA.Space.xs))
      : AnyLayout(HStackLayout(spacing: LLA.Space.xs))
    return layout {
      if stacked {
        HStack(alignment: .top, spacing: LLA.Space.s) {
          if line.marked { ThreadMark(state: .working).accessibilityHidden(true) }
          if !segments.isEmpty { parts }
        }
      } else {
        if line.marked { ThreadMark(state: .working).accessibilityHidden(true) }
        if !segments.isEmpty { parts }
      }
      if Self.ticks(line), let start = line.startedAt { ActivityClock(start: start).fixedSize() }
      if let action = line.action(open: open) {
        Text(action)
          .foregroundStyle(LLA.Color.muted)
          .lineLimit(stacked ? nil : 1)
          .fixedSize(horizontal: !stacked, vertical: true)
      }
    }
    .font(LLAFont.small)
    .frame(maxWidth: .infinity, minHeight: LLA.Metrics.row, alignment: .leading)
    .contentShape(Rectangle())
  }

  /// A run of the line drawn in one colour.
  struct Segment: Equatable {
    enum Tone: Equatable { case muted, danger }
    var text: String
    var tone: Tone
  }

  /// The text, "N failed" (danger, and only it) and "N declined", with a muted ", " between the parts
  /// that are present, then an ended line's duration after " · ". The action word and the clock are not
  /// part of it.
  var segments: [Segment] {
    var segments: [Segment] = []
    func add(_ text: String?, _ tone: Segment.Tone) {
      guard let text else { return }
      if !segments.isEmpty { segments.append(Segment(text: ", ", tone: .muted)) }
      segments.append(Segment(text: text, tone: tone))
    }
    add(line.text, .muted)
    add(line.failedText, .danger)
    add(line.declinedText, .muted)
    if let duration = line.durationText {
      segments.append(Segment(text: " · ", tone: .muted))
      segments.append(Segment(text: duration, tone: .muted))
    }
    return segments
  }

  private func styled(_ segment: Segment) -> Text {
    Text(segment.text).foregroundStyle(segment.tone == .danger ? LLA.Color.danger : LLA.Color.muted)
  }

  /// The segments. On one line the text is the only part that shrinks, cut at its tail; stacked they
  /// are one text that wraps as a whole, so no part is squeezed by the ones beside it.
  @ViewBuilder private var parts: some View {
    if typeSize.isAccessibilitySize {
      segments.dropFirst().reduce(styled(segments[0])) { Text("\($0)\(styled($1))") }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(spokenWords)
    } else {
      HStack(spacing: 0) {
        ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
          if index == 0, line.text != nil {
            styled(segment).lineLimit(1).truncationMode(.tail)
          } else {
            styled(segment).fixedSize()
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(spokenWords)
    }
  }

  /// The line's words, as the screen reader has them ahead of the clock and the action.
  private var spokenWords: String {
    [line.text, line.failedText, line.declinedText, line.durationText].compactMap { $0 }
      .joined(separator: ", ")
  }
}

/// The time since a turn began, once a second. It is the only view that reads the time: the row, the
/// transcript and the projection around it are not drawn again for a tick.
struct ActivityClock: View {
  let start: String

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let seconds = ActivityTime.seconds(since: start, now: context.date)
      Text(ActivityTime.clock(seconds))
        .monospacedDigit()
        .foregroundStyle(LLA.Color.muted)
        .lineLimit(1)
        .accessibilityLabel(ActivityTime.words(seconds))
    }
  }
}

/// The phone's own message before the Mac has it: the user's bubble as the transcript draws it, with
/// "Sending…", "Not confirmed: …", or "Didn't reach your Mac" under it.
struct PendingMessageRow: View {
  let send: PendingSend
  let status: String?

  var body: some View {
    VStack(alignment: .trailing, spacing: LLA.Space.xs) {
      HStack {
        Spacer(minLength: 60)
        Text(send.text)
          .llaBody()
          .textSelection(.enabled)
          .padding(.horizontal, LLA.Space.l)
          .padding(.vertical, LLA.Space.m)
          .background(
            RoundedRectangle(cornerRadius: LLA.Radius.card, style: .continuous).fill(LLA.Color.surface)
          )
          .opacity(send.state == .sending ? 0.7 : 1)
      }
      if let status {
        HStack(spacing: LLA.Space.xs) {
          if send.state == .sending { ProgressView().controlSize(.mini).accessibilityHidden(true) }
          Text(status)
            .font(LLAFont.caption)
            .foregroundStyle(send.state == .sending ? LLA.Color.muted : LLA.Color.danger)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("pending-message")
  }
}

/// A user's message, a reply, a plan row or a system item. Work (a tool, reasoning) reaches the screen
/// as a step row (`StepRowView`), never here.
struct TranscriptRow: View {
  let item: DisplayItem
  let streams: MessageStreamStore

  var body: some View {
    switch item.role {
    case .user:
      HStack {
        Spacer(minLength: 60)
        Text(item.payload["text"]?.stringValue ?? "")
          .llaBody()
          .textSelection(.enabled)
          .padding(.horizontal, LLA.Space.l)
          .padding(.vertical, LLA.Space.m)
          .background(
            RoundedRectangle(cornerRadius: LLA.Radius.card, style: .continuous).fill(LLA.Color.surface))
      }
    case .assistant:
      if item.type == "agentMessage" {
        // The parser drops blank lines at either end, so nothing is trimmed here.
        MarkdownText(
          document: streams.document(for: item),
          streaming: item.nativeItemId.map(streams.isStreaming) ?? false)
      }
    case .tool:
      if item.type == TaskList.itemType, let display = TaskListDisplay(item: item) {
        TaskListRow(display: display)
      }
    case .system:
      Text(item.type).llaCaption()
    }
  }
}

/// A fenced block: its language, Copy, and the code at its full height, scrolling sideways inside the
/// block when a line is wider than the column. Copy takes the code exactly, without fence or language.
struct CodeFence: View, Equatable {
  let language: String?
  let code: String
  let copyable: Bool
  @State private var copied = false

  nonisolated static func == (lhs: CodeFence, rhs: CodeFence) -> Bool {
    lhs.language == rhs.language && lhs.code == rhs.code && lhs.copyable == rhs.copyable
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: LLA.Space.s) {
        Text(language ?? "code").font(LLAFont.caption).foregroundStyle(LLA.Color.codeFg.opacity(0.7))
        Spacer()
        if copyable {
          Button(copied ? "Copied" : "Copy") {
            Clipboard.copy(code)
            copied = true
            Task {
              try? await Task.sleep(for: .seconds(2))
              copied = false
            }
          }
          .buttonStyle(.plain)
          .font(LLAFont.caption)
          .foregroundStyle(LLA.Color.codeFg)
          .frame(minHeight: LLA.Metrics.row)
          .contentShape(Rectangle())
          .accessibilityLabel(copied ? "Copied" : "Copy code")
          .accessibilityIdentifier("copy-code")
        }
      }
      .padding(.horizontal, LLA.Space.m)
      .frame(minHeight: max(LLA.Metrics.row, 32))
      ScrollView(.horizontal) {
        Text(code.isEmpty ? " " : code)
          .font(LLAFont.codeSmall)
          .foregroundStyle(LLA.Color.codeFg)
          .textSelection(.enabled)
          .fixedSize(horizontal: true, vertical: true)
          .padding([.horizontal, .bottom], LLA.Space.m)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: LLA.Radius.card, style: .continuous).fill(LLA.Color.codeBg))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(language.map { "\($0) code" } ?? "Code")
  }
}

/// The system pasteboard, for a Copy the reader pressed.
enum Clipboard {
  @MainActor static func copy(_ text: String) {
    #if os(macOS)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    #else
      UIPasteboard.general.string = text
    #endif
  }
}

/// How a turn that did not complete ended. Only a recorded failure is drawn as one: a turn that is
/// terminal with no outcome (its status synced ahead of its outcome, or an outcome this build does
/// not know) says only that it ended, as the list and the hub's notifications already read it.
struct TurnNoteRow: View {
  let turn: Turn

  var text: String {
    switch turn.outcome {
    case .failed: "Turn failed."
    case .cancelled: "Turn stopped."
    case .completed, nil: "Turn ended."
    }
  }
  var isFailure: Bool { turn.outcome == .failed }

  var body: some View {
    Text(text)
      .font(LLAFont.caption)
      .foregroundStyle(isFailure ? LLA.Color.danger : LLA.Color.muted)
  }
}
