import SwiftUI

/// The parts the keyboard-driven lists share (D-227): the command palette, the composer's `/` list
/// and the folder picker draw the same card, section heading, row and footer, so the three read as
/// one control. Each list keeps its own model and keys; only the drawing is here.
enum PickerMetrics {
  static let rowHeight: CGFloat = 32
  /// The room around the rows, inside the card.
  static let inset: CGFloat = LLA.Space.s
  /// A section heading's whole height, so a list can be sized before it is drawn.
  static let sectionHeight: CGFloat = 28
  static let footerHeight: CGFloat = LLA.Space.xxl
  /// The field's row, which sits over the title bar's button when the palette opens there.
  static let fieldHeight: CGFloat = 36
  /// The card's corners: half the field row, so the row alone (the title bar's resting control) is
  /// a capsule, the shape of the button groups beside it, and the card keeps those corners as it
  /// opens. Circular, as a capsule's ends are.
  static let radius: CGFloat = fieldHeight / 2
  static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .circular) }
  /// The widest a trailing value is drawn before it is cut.
  static let trailingWidth: CGFloat = 220
}

/// What leads a row: a symbol or a mark, in a square the titles line up after.
struct PickerLead<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    content
      .frame(width: LLA.Space.l, height: LLA.Space.l)
      .accessibilityHidden(true)
  }
}

/// A row's SF Symbol, at the size and colour every list draws it.
struct PickerSymbol: View {
  let name: String

  var body: some View {
    PickerLead {
      Image(systemName: name).font(.system(size: 13, weight: .regular)).foregroundStyle(LLA.Color.muted)
    }
  }
}

/// A heading over a group of rows.
struct PickerSectionTitle: View {
  let title: String

  init(_ title: String) { self.title = title }

  var body: some View {
    Text(title).llaSmallMuted().lineLimit(1)
      .padding(.horizontal, LLA.Space.s).padding(.bottom, LLA.Space.xs)
      .frame(maxWidth: .infinity, minHeight: PickerMetrics.sectionHeight, alignment: .bottomLeading)
      .frame(height: PickerMetrics.sectionHeight)
      .accessibilityAddTraits(.isHeader)
  }
}

/// One selectable row: a lead, a title, a quieter note, and at the trailing edge a value, the
/// "Current" mark, a shortcut in caps and the chevron of a row with actions. The selected row's
/// highlight is the shared one, which glides between rows (D-222).
struct PickerRow<Lead: View, Title: View>: View {
  var selected: Bool
  var highlight: Namespace.ID
  var height: CGFloat = PickerMetrics.rowHeight
  var secondary: String?
  var trailing: String?
  var trailingFont: Font = LLAFont.caption
  var trailingTruncation: Text.TruncationMode = .tail
  /// The widest the value is drawn; nil lets it take the room the title leaves.
  var trailingWidth: CGFloat? = PickerMetrics.trailingWidth
  var isCurrent = false
  var shortcut: String?
  var hasActions = false
  /// A row under another: its lead starts this far in.
  var indent: CGFloat = 0
  @ViewBuilder var lead: Lead
  @ViewBuilder var title: Title

  var body: some View {
    HStack(spacing: LLA.Space.s) {
      lead
      title.lineLimit(1).layoutPriority(1)
      if let secondary {
        Text(secondary).llaCaption().lineLimit(1)
      }
      Spacer(minLength: LLA.Space.s)
      if let trailing {
        // A value or a state is short and shown whole; a path or an argument hint can be a line
        // long, and is cut before it pushes the row wider than the card.
        let value = Text(trailing).font(trailingFont).foregroundStyle(LLA.Color.muted)
          .lineLimit(1).truncationMode(trailingTruncation)
        if let trailingWidth {
          value.frame(maxWidth: trailingWidth, alignment: .trailing).fixedSize(
            horizontal: true, vertical: false)
        } else {
          value
        }
      }
      if isCurrent {
        Text("Current").llaCaption().fixedSize()
        Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
          .foregroundStyle(LLA.Color.ink).accessibilityHidden(true)
      }
      #if os(macOS)
        if let shortcut {
          KeyCaps(label: shortcut)
        }
      #endif
      if hasActions {
        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
          .foregroundStyle(LLA.Color.ghost).accessibilityHidden(true)
      }
    }
    .padding(.leading, LLA.Space.s + indent)
    .padding(.trailing, LLA.Space.s)
    .frame(height: height)
    .selectionHighlight(selected, in: highlight)
    .contentShape(Rectangle())
  }
}

/// A footer hint: what a key does, and the key in caps. VoiceOver and the tooltip name the key. The
/// primary action's words are in the ink colour; the others are muted.
struct PickerHint: View {
  let title: String
  var keys: [HintKey] = []
  var strong = false
  let action: () -> Void

  init(_ title: String, keys: [HintKey] = [], strong: Bool = false, action: @escaping () -> Void) {
    self.title = title
    self.keys = keys
    self.strong = strong
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: LLA.Space.s) {
        Text(title).font(LLAFont.caption).foregroundStyle(strong ? LLA.Color.ink : LLA.Color.muted)
          .lineLimit(1)
        #if os(macOS)
          if !keys.isEmpty { KeyCaps(keys) }
        #endif
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    // The context beside the hints is what gives way in a narrow card, never a hint's words.
    .fixedSize()
    .help(keys.isEmpty ? "" : HintKey.spoken(keys))
    .accessibilityLabel(keys.isEmpty ? title : "\(title), \(HintKey.spoken(keys))")
  }
}

/// The line under the rows: at the leading edge what the selected row applies to (or a failure),
/// and at the trailing edge the keys.
struct PickerFooter<Hints: View>: View {
  var context: String
  var isFailure = false
  /// Something asked for is still running.
  var busy = false
  var contextIdentifier = "picker-context"
  @ViewBuilder var hints: Hints

  var body: some View {
    HStack(spacing: LLA.Space.l) {
      HStack(spacing: LLA.Space.s) {
        if busy {
          ProgressView().controlSize(.mini).accessibilityHidden(true)
        }
        Text(context)
          .font(LLAFont.caption)
          .foregroundStyle(isFailure ? LLA.Color.danger : LLA.Color.muted)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier(contextIdentifier)
      hints
    }
    .padding(.horizontal, LLA.Space.l)
    .frame(height: PickerMetrics.footerHeight)
  }
}

extension View {
  /// The card every picker is drawn on. In a panel of its own the window draws the shadow.
  func pickerCard(shadow: Bool = true) -> some View {
    background(LLA.Color.bg, in: PickerMetrics.shape)
      .overlay(PickerMetrics.shape.strokeBorder(LLA.Color.rule))
      .clipShape(PickerMetrics.shape)
      .shadow(
        color: LLA.Color.ink.opacity(shadow ? 0.12 : 0), radius: shadow ? 18 : 0, x: 0, y: shadow ? 8 : 0)
  }
}

#if os(macOS)
  /// The pointer's last place, so a row is selected by the pointer only when the pointer itself
  /// moved: a list that scrolls or changes under a still pointer keeps the keyboard's selection.
  final class PointerTracker {
    private var last: CGPoint?

    func moved(to point: CGPoint) -> Bool {
      defer { last = point }
      guard let last else { return false }
      return abs(last.x - point.x) > 0.5 || abs(last.y - point.y) > 0.5
    }
  }
#endif

extension View {
  /// The pointer takes the highlight with the same glide as the keys (D-222), and only when it is
  /// the pointer that moved. Nothing on a phone, which has no pointer to follow.
  @ViewBuilder func pickerHover(_ select: @escaping () -> Void) -> some View {
    #if os(macOS)
      modifier(PickerHover(select: select))
    #else
      self
    #endif
  }
}

#if os(macOS)
  /// The list's pointer tracker, shared by its rows.
  private struct PickerPointerKey: EnvironmentKey {
    static let defaultValue = PointerTracker()
  }

  extension EnvironmentValues {
    var pickerPointer: PointerTracker {
      get { self[PickerPointerKey.self] }
      set { self[PickerPointerKey.self] = newValue }
    }
  }

  private struct PickerHover: ViewModifier {
    let select: () -> Void
    @Environment(\.pickerPointer) private var pointer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
      content.onContinuousHover(coordinateSpace: .global) { phase in
        guard case .active(let point) = phase, pointer.moved(to: point) else { return }
        withAnimation(SelectionMotion.animation(reduceMotion: reduceMotion), select)
      }
    }
  }
#endif
