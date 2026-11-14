import SwiftUI

/// One key of a keyboard shortcut, as a hint draws and says it (D-221).
public enum HintKey: Hashable, Sendable {
  case command, shift, option, control, tab, `return`, escape
  /// A printed key: a letter, a digit, a mark.
  case character(String)

  /// The SF Symbol of a key that has one. Tab is the compact arrow, which sits in a cap with room
  /// either side where the full one touches its edges. Escape has none: it is the word on the key.
  public var symbol: String? {
    switch self {
    case .command: "command"
    case .shift: "shift"
    case .option: "option"
    case .control: "control"
    case .tab: "arrow.right.to.line.compact"
    case .return: "return"
    case .escape, .character: nil
    }
  }

  /// What the cap prints for a key with no symbol: the word on the Escape key (D-226), or the
  /// character.
  public var legend: String {
    switch self {
    case .escape: "esc"
    default: name
    }
  }

  /// The key's name, for VoiceOver and the tooltip: the words Apple's style guide uses.
  public var name: String {
    switch self {
    case .command: "Command"
    case .shift: "Shift"
    case .option: "Option"
    case .control: "Control"
    case .tab: "Tab"
    case .return: "Return"
    case .escape: "Escape"
    case .character(let character): character.uppercased()
    }
  }

  /// The keys of a label written in the menu bar's glyphs ("⇧⌘P"), in the order written.
  public static func keys(in label: String) -> [HintKey] {
    label.map { character in
      switch character {
      case "\u{2318}": .command
      case "\u{21E7}": .shift
      case "\u{2325}": .option
      case "\u{2303}": .control
      case "\u{21E5}": .tab
      case "\u{21A9}": .return
      case "\u{238B}": .escape
      default: .character(String(character))
      }
    }
  }

  /// The keys said together: "Shift-Command-P".
  public static func spoken(_ keys: [HintKey]) -> String {
    keys.map(\.name).joined(separator: "-")
  }
}

/// A key drawn as a small cap: its SF Symbol, or its word or character, at the weight of the text beside it.
public struct KeyCap: View {
  let key: HintKey

  public init(_ key: HintKey) { self.key = key }

  public static let height: CGFloat = 18
  static let shape = RoundedRectangle(cornerRadius: 4.5, style: .continuous)

  public var body: some View {
    Group {
      if let symbol = key.symbol {
        Image(systemName: symbol).font(.system(size: 10.5, weight: .medium))
      } else {
        Text(key.legend).font(.system(size: 11, weight: .medium))
      }
    }
    .foregroundStyle(LLA.Color.muted)
    .padding(.horizontal, 5)
    .frame(minWidth: 20, minHeight: Self.height)
    .background(Self.shape.fill(LLA.Color.surface))
    .overlay(Self.shape.strokeBorder(LLA.Color.ghost.opacity(0.7), lineWidth: 1))
    .fixedSize()
  }
}

/// The caps of one shortcut, side by side. It is decoration: whatever shows it says the keys in its
/// own label (`HintKey.spoken`).
public struct KeyCaps: View {
  let keys: [HintKey]

  public init(_ keys: [HintKey]) { self.keys = keys }

  /// The caps of a label in the menu bar's glyphs.
  public init(label: String) { self.keys = HintKey.keys(in: label) }

  public var body: some View {
    HStack(spacing: 3) {
      ForEach(Array(keys.enumerated()), id: \.offset) { _, key in KeyCap(key) }
    }
    .accessibilityHidden(true)
  }
}
