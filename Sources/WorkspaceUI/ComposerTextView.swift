import SwiftUI

/// What a key that the text system turned into a command does in the composer (D-219): Return sends,
/// Shift-, Option- and Control-Return add a line, Command-Return sends too, and while an input method
/// is composing (Japanese, Chinese, Korean) every key is the input method's, so the Return that
/// commits a candidate never sends. Return means the same whatever the draft holds or the thread is
/// doing; when nothing can be sent it does nothing rather than adding a line.
enum ComposerKey: Equatable {
  /// Leave the command to the text view.
  case system
  /// Insert a line break.
  case newline
  /// Ask the caller to send.
  case send

  /// The selectors are AppKit's standard key bindings: Return and Shift-Return both arrive as
  /// `insertNewline:`, so Shift is read from the event; Option-Return is
  /// `insertNewlineIgnoringFieldEditor:`, Control-Return `insertLineBreak:` (which would insert a
  /// U+2028 separator, so it becomes a plain line too), and Command-Return `noop:`.
  static func action(
    for selector: String, shift: Bool, command: Bool, returnKey: Bool, composing: Bool
  ) -> ComposerKey {
    guard !composing else { return .system }
    switch selector {
    case "insertNewline:": return shift ? .newline : .send
    case "insertNewlineIgnoringFieldEditor:", "insertLineBreak:": return .newline
    case "noop:": return command && returnKey ? .send : .system
    default: return .system
    }
  }
}

#if os(macOS)
  import AppKit

  /// The Mac composer's editor (D-219): an `NSTextView` in an `NSScrollView`. It reports its own height,
  /// one line to `maxLines`, so the frame SwiftUI clamps is the scroll view itself, and text past the
  /// last line scrolls inside it with the caret kept in view instead of spilling out of the field.
  /// Return is decided in the text view's command handler, after the input method has had the key.
  struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let label: String
    let maxLines: Int
    /// The keys the `/` completions take while they show, before the text view or `onReturn` has
    /// them; false leaves the key where it was going. Never while an input method is composing.
    var onSlashKey: ((SlashKey) -> Bool)?
    let onReturn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ComposerScrollView {
      let scroll = ComposerScrollView()
      scroll.drawsBackground = false
      scroll.borderType = .noBorder
      scroll.hasVerticalScroller = true
      scroll.hasHorizontalScroller = false
      scroll.autohidesScrollers = true
      scroll.scrollerStyle = .overlay
      scroll.focusRingType = .none

      let textView = context.coordinator.textView
      textView.delegate = context.coordinator
      textView.string = text
      scroll.documentView = textView
      return scroll
    }

    func updateNSView(_ scroll: ComposerScrollView, context: Context) {
      let coordinator = context.coordinator
      coordinator.parent = self
      let textView = coordinator.textView
      // Never while an input method holds marked text: replacing the string would drop the
      // candidate the person is choosing.
      if textView.string != text, !textView.hasMarkedText() {
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
      }
      let enabled = context.environment.isEnabled
      textView.isEditable = enabled
      textView.isSelectable = enabled
      textView.setAccessibilityLabel(label)
    }

    func sizeThatFits(
      _ proposal: ProposedViewSize, nsView: ComposerScrollView, context: Context
    )
      -> CGSize?
    {
      let width = proposal.width ?? nsView.frame.width
      return CGSize(
        width: width, height: context.coordinator.height(forWidth: width, maxLines: maxLines))
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
      var parent: ComposerTextView
      let textView: ComposerNSTextView
      /// A TextKit 1 stack that lays the draft out at any width, so measuring never moves the
      /// editor's own caret or scroll position.
      private let measureStorage = NSTextStorage()
      private let measureLayout = NSLayoutManager()
      private let measureContainer = NSTextContainer()

      init(_ parent: ComposerTextView) {
        self.parent = parent
        textView = ComposerNSTextView.make()
        measureContainer.lineFragmentPadding = 0
        measureLayout.addTextContainer(measureContainer)
        measureStorage.addLayoutManager(measureLayout)
      }

      /// The draft's height at `width`: one line at least, `maxLines` at most.
      func height(forWidth width: CGFloat, maxLines: Int) -> CGFloat {
        let font = ComposerNSTextView.font
        let line = measureLayout.defaultLineHeight(for: font)
        guard width > 0 else { return line }
        measureContainer.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        measureStorage.setAttributedString(
          NSAttributedString(string: textView.string, attributes: [.font: font]))
        measureLayout.ensureLayout(for: measureContainer)
        var used = measureLayout.usedRect(for: measureContainer).maxY
        // A trailing newline lays out as the extra line fragment, which `usedRect` leaves out.
        if measureLayout.extraLineFragmentTextContainer === measureContainer {
          used = max(used, measureLayout.extraLineFragmentRect.maxY)
        }
        return min(max(ceil(used), line), line * CGFloat(max(maxLines, 1)))
      }

      func textDidChange(_ notification: Notification) {
        parent.text = textView.string
        textView.scrollCaretIntoView()
      }

      func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let event = (textView as? ComposerNSTextView)?.keyEvent
        let flags = event?.modifierFlags ?? []
        let returnKey = event?.type == .keyDown && (event?.keyCode == 36 || event?.keyCode == 76)
        if !textView.hasMarkedText(), let key = SlashKey(command: NSStringFromSelector(selector)),
          parent.onSlashKey?(key) == true
        {
          return true
        }
        switch ComposerKey.action(
          for: NSStringFromSelector(selector), shift: flags.contains(.shift),
          command: flags.contains(.command), returnKey: returnKey, composing: textView.hasMarkedText())
        {
        case .system:
          return false
        case .newline:
          textView.insertNewlineIgnoringFieldEditor(nil)
          return true
        case .send:
          // The completions take Return first: with them showing it picks one and never sends.
          if parent.onSlashKey?(.choose) != true { parent.onReturn() }
          return true
        }
      }
    }
  }

  /// Keeps the caret in view whenever SwiftUI changes the field's height, so growing to the last line
  /// or shrinking after a delete never leaves the caret under the edge.
  final class ComposerScrollView: NSScrollView {
    private var lastHeight: CGFloat = 0

    override func layout() {
      super.layout()
      if frame.height != lastHeight {
        lastHeight = frame.height
        (documentView as? ComposerNSTextView)?.scrollCaretIntoView()
      }
    }
  }

  final class ComposerNSTextView: NSTextView {
    /// The key being handled, for its modifiers: Return and Shift-Return reach the delegate as the
    /// same command. Nil outside `keyDown`, so a command from a menu or a test is never a key.
    private(set) var keyEvent: NSEvent?

    override func keyDown(with event: NSEvent) {
      keyEvent = event
      defer { keyEvent = nil }
      super.keyDown(with: event)
    }

    static var font: NSFont { LLAFont.composerNSFont }

    static func make() -> ComposerNSTextView {
      // TextKit 1, the same layout the measuring stack uses, so the reported height is the drawn one.
      let storage = NSTextStorage()
      let layout = NSLayoutManager()
      storage.addLayoutManager(layout)
      let container = NSTextContainer(
        size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
      container.widthTracksTextView = true
      container.lineFragmentPadding = 0
      layout.addTextContainer(container)
      let view = ComposerNSTextView(frame: .zero, textContainer: container)
      view.minSize = .zero
      view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
      view.isVerticallyResizable = true
      view.isHorizontallyResizable = false
      view.autoresizingMask = [.width]
      view.textContainerInset = .zero
      view.drawsBackground = false
      view.isRichText = false
      view.importsGraphics = false
      view.allowsUndo = true
      view.usesFindBar = false
      view.font = font
      view.textColor = LLA.Palette.ink.nsColor
      view.insertionPointColor = LLA.Palette.accent.nsColor
      view.typingAttributes = [.font: font, .foregroundColor: LLA.Palette.ink.nsColor]
      view.focusRingType = .none
      view.setAccessibilityIdentifier("composer")
      return view
    }

    func scrollCaretIntoView() {
      guard let layoutManager, let textContainer else { return }
      layoutManager.ensureLayout(for: textContainer)
      scrollRangeToVisible(selectedRange())
    }
  }
#endif
