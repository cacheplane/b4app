import AppKit
import SwiftUI
import Testing

@testable import WorkspaceUI

/// D-219: what each Return does in the composer.
struct ComposerKeyTests {
  private func action(
    _ selector: String, shift: Bool = false, command: Bool = false, returnKey: Bool = true,
    composing: Bool = false
  ) -> ComposerKey {
    ComposerKey.action(
      for: selector, shift: shift, command: command, returnKey: returnKey, composing: composing)
  }

  @Test func returnSendsAndTheModifiedReturnsAddALine() {
    #expect(action("insertNewline:") == .send)
    #expect(action("insertNewline:", shift: true) == .newline)
    #expect(action("insertNewlineIgnoringFieldEditor:") == .newline)
    #expect(action("insertLineBreak:") == .newline)
    #expect(action("noop:", command: true) == .send)
    // Command with another key, or a key AppKit binds to nothing, stays the system's.
    #expect(action("noop:", command: true, returnKey: false) == .system)
    #expect(action("noop:") == .system)
    #expect(action("insertTab:") == .system)
    #expect(action("deleteBackward:") == .system)
  }

  @Test func everyKeyIsTheInputMethodsWhileItComposes() {
    for selector in ["insertNewline:", "insertNewlineIgnoringFieldEditor:", "insertLineBreak:", "noop:"] {
      #expect(action(selector, command: true, composing: true) == .system)
      #expect(action(selector, shift: true, composing: true) == .system)
    }
  }
}

/// The Mac's editor hosted in a window, as the composer draws it.
@Suite(.serialized) @MainActor struct ComposerTextViewTests {
  @Observable final class Draft {
    var text = ""
    var returns = 0
  }

  struct Harness: View {
    @Bindable var draft: Draft
    @FocusState private var focused: Bool

    var body: some View {
      ComposerField(
        text: $draft.text, placeholder: "Message Codex", focused: $focused,
        onReturn: { draft.returns += 1 }
      ) {
        Circle().fill(LLA.Color.ink).frame(width: ComposerField<EmptyView>.control)
      }
      .frame(width: 560)
      .padding(20)
      .onAppear { focused = true }
    }
  }

  private func host(_ draft: Draft) -> SnapshotWindow<some View> {
    SnapshotWindow(
      rootView: Harness(draft: draft).background(LLA.Color.bg).frame(
        width: 600, height: 400, alignment: .topLeading),
      untitled: true, size: CGSize(width: 600, height: 400))
  }

  private func settle(_ window: SnapshotWindow<some View>) async {
    for _ in 0..<6 {
      window.host.layoutSubtreeIfNeeded()
      try? await Task.sleep(for: .milliseconds(30))
    }
  }

  private func editor(in view: NSView) -> ComposerNSTextView? {
    if let found = view as? ComposerNSTextView { return found }
    for child in view.subviews { if let found = editor(in: child) { return found } }
    return nil
  }

  /// With B4APP_SNAPSHOT_DIR, the window in both appearances, for looking over by eye.
  private func capture(_ window: SnapshotWindow<some View>, _ name: String) async throws {
    guard let directory = ProcessInfo.processInfo.environment["B4APP_SNAPSHOT_DIR"] else { return }
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
      window.appearance = NSAppearance(named: appearance)
      try await window.capture(
        to: "\(directory)/\(name)-\(suffix).png", crop: CGSize(width: 600, height: 200))
    }
    window.appearance = nil
  }

  private var line: CGFloat { NSLayoutManager().defaultLineHeight(for: LLAFont.composerNSFont) }

  @Test func theFieldStopsAtThreeLinesAndScrollsWithTheCaretInView() async throws {
    let draft = Draft()
    let window = host(draft)
    defer { window.window.close() }
    await settle(window)
    let textView = try #require(editor(in: window.host))
    let scroll = try #require(textView.enclosingScrollView)
    #expect(abs(scroll.frame.height - line) < 1)
    let empty = window.host.fittingSize.height
    try await capture(window, "composerEmpty")

    // Twelve lines, typed as a person would: the field grows to three and no further.
    var threeLines: CGFloat = 0
    for index in 0..<12 {
      if index > 0 { textView.doCommand(by: #selector(NSTextView.insertNewlineIgnoringFieldEditor(_:))) }
      textView.insertText("line \(index + 1)", replacementRange: textView.selectedRange())
      if index == 0 {
        await settle(window)
        try await capture(window, "composerOneLine")
      }
      if index == 2 {
        await settle(window)
        #expect(abs(scroll.frame.height - line * 3) < 1)
        threeLines = window.host.fittingSize.height
      }
    }
    await settle(window)
    #expect(draft.text.split(separator: "\n").count == 12)
    #expect(abs(scroll.frame.height - line * 3) < 1)
    // The whole field is as tall as it was at three lines: the text never spills past its background.
    #expect(abs(window.host.fittingSize.height - threeLines) < 1)
    // The rest scrolls inside, and the last line, where the caret is, is in view.
    #expect(textView.frame.height > scroll.frame.height + line * 8)
    let visible = scroll.contentView.bounds
    #expect(visible.maxY >= textView.frame.height - 1)
    try await capture(window, "composerFull")

    // Blank lines too, the case that spilled out of the old field: Return-less newlines at the end.
    for _ in 0..<6 { textView.doCommand(by: #selector(NSTextView.insertNewlineIgnoringFieldEditor(_:))) }
    await settle(window)
    #expect(abs(scroll.frame.height - line * 3) < 1)
    #expect(scroll.contentView.bounds.maxY >= textView.frame.height - 1)

    // Clearing the draft, as a send does, brings it back to one line.
    draft.text = ""
    await settle(window)
    #expect(abs(scroll.frame.height - line) < 1)
    #expect(abs(window.host.fittingSize.height - empty) < 1)
  }

  @Test func returnGoesToTheCallerAndTheModifiedReturnsAddALine() async throws {
    let draft = Draft()
    let window = host(draft)
    defer { window.window.close() }
    await settle(window)
    let textView = try #require(editor(in: window.host))
    #expect(window.window.firstResponder === textView)

    textView.insertText("hello", replacementRange: textView.selectedRange())
    textView.doCommand(by: #selector(NSTextView.insertNewline(_:)))
    #expect(draft.returns == 1)
    #expect(draft.text == "hello")

    textView.doCommand(by: #selector(NSTextView.insertNewlineIgnoringFieldEditor(_:)))
    textView.doCommand(by: #selector(NSTextView.insertLineBreak(_:)))
    #expect(draft.returns == 1)
    // A plain line feed both times, never the U+2028 separator Control-Return would insert.
    #expect(draft.text == "hello\n\n")
  }

  /// Real key events, as the window delivers them: the text system (and any input method) turns
  /// each into its command, and the delegate reads Shift from the event.
  @Test func realReturnKeysSendOrAddALine() async throws {
    let draft = Draft()
    let window = host(draft)
    defer { window.window.close() }
    await settle(window)
    let textView = try #require(editor(in: window.host))
    textView.insertText("hi", replacementRange: textView.selectedRange())

    func press(_ flags: NSEvent.ModifierFlags, keyCode: UInt16 = 36) throws {
      let event = try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
          windowNumber: window.window.windowNumber, context: nil, characters: "\r",
          charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: keyCode))
      textView.keyDown(with: event)
    }

    try press([])
    #expect(draft.returns == 1 && draft.text == "hi")
    try press(.shift)
    try press(.option)
    try press(.control)
    #expect(draft.returns == 1 && draft.text == "hi\n\n\n")
    try press(.command)
    try press([], keyCode: 76)  // The keypad's Enter.
    #expect(draft.returns == 3 && draft.text == "hi\n\n\n")
  }

  @Test func theReturnThatCommitsAnInputMethodsCandidateNeverSends() async throws {
    let draft = Draft()
    let window = host(draft)
    defer { window.window.close() }
    await settle(window)
    let textView = try #require(editor(in: window.host))

    textView.setMarkedText(
      "にほんご", selectedRange: NSRange(location: 4, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(textView.hasMarkedText())
    let delegate = try #require(textView.delegate)
    let handled = delegate.textView?(textView, doCommandBy: #selector(NSTextView.insertNewline(_:)))
    #expect(handled == false)
    #expect(draft.returns == 0)
  }
}
