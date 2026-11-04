import SwiftUI

/// D-061: one rounded field in two shapes, for the thread composer and a new thread's first message.
/// The box (every iPhone, and any wider screen once the draft wraps) has the text on top and a tool
/// row underneath, the trailing control at its end. The line (iPad and Mac while the draft fits) is a
/// 44 pt capsule with the control inline. The text grows to three lines, then scrolls. Attachments,
/// when a turn can carry them, go in a row between the text and the tool row, with attach at the tool
/// row's leading end; neither is drawn until then.
///
/// The field owns the editor, the capsule, and the shape; the caller owns what the text means and
/// supplies the control, sized by `ComposerField.scale` and the metrics below.
struct ComposerField<Trailing: View>: View {
  @Binding var text: String
  let placeholder: String
  var focused: FocusState<Bool>.Binding
  /// Return in the editor where it can submit: the phone's text field. The Mac's `TextEditor` takes
  /// Return as its own, so there the caller's control owns the shortcut.
  let onSubmit: () -> Void
  let trailing: Trailing
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
  /// How far Dynamic Type has grown the draft text; the line and the control follow it up to 1.5
  /// times, so the control stays a meaningful size beside large text without crowding the field.
  @ScaledMetric(relativeTo: .callout) private var growth: CGFloat = 1

  init(
    text: Binding<String>, placeholder: String, focused: FocusState<Bool>.Binding,
    onSubmit: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing
  ) {
    _text = text
    self.placeholder = placeholder
    self.focused = focused
    self.onSubmit = onSubmit
    self.trailing = trailing()
  }

  var body: some View {
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
        trailing
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

  // MARK: Metrics

  /// The line's height and the control's diameter at the default text size. The control sits
  /// `inset` from the field's edge on every side it touches, so its circle is concentric with the
  /// field's corner.
  static var line: CGFloat { 44 }
  static var control: CGFloat { 32 }
  static var inset: CGFloat { (line - control) / 2 }
  /// Text starts 16 pt in from the field's edge in both shapes.
  static var textLeading: CGFloat { 16 }
  /// Between the last line of text and the tool row in the box.
  static var toolGap: CGFloat { 4 }

  /// The factor the line and the control grow by for a Dynamic Type `growth` (a `ScaledMetric` of 1).
  static func scale(_ growth: CGFloat) -> CGFloat { min(max(growth, 1), 1.5) }

  private var scale: CGFloat { Self.scale(growth) }
  private var lineSize: CGFloat { Self.line * scale }
  private var controlSize: CGFloat { Self.control * scale }
  private var insetSize: CGFloat { Self.inset * scale }

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
      wide: wide, accessibilitySize: typeSize.isAccessibilitySize, draft: text,
      draftWidth: draftWidth, fieldWidth: fieldWidth, control: controlSize, inset: insetSize)
  }

  /// The line only where the screen is wide, the text is not at an accessibility size, and the draft
  /// has no line break and fits on one line beside the control; the box otherwise. Before the field
  /// has a width, a wide screen starts with the line.
  static func shape(
    wide: Bool, accessibilitySize: Bool, draft: String, draftWidth: CGFloat, fieldWidth: CGFloat,
    control: CGFloat = control, inset: CGFloat = inset
  ) -> Shape {
    guard wide, !accessibilitySize, !draft.contains("\n") else { return .box }
    let room = fieldWidth - textLeading - LLA.Space.s - control - inset
    return fieldWidth == 0 || draftWidth <= room ? .line : .box
  }

  // MARK: The editor

  /// Hidden copies of one line and of the draft on one line, in the field's font.
  private var measurements: some View {
    ZStack(alignment: .topLeading) {
      Text("Ag").font(LLAFont.composer)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { lineHeight = $0 }
      Text(text.isEmpty ? placeholder : text)
        .font(LLAFont.composer).lineLimit(1).fixedSize()
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { draftWidth = $0 }
    }
    .hidden()
    .accessibilityHidden(true)
  }

  #if os(iOS)
    /// A vertical text field: it grows a line at a time to three, then scrolls, with no inner inset,
    /// so its text sits exactly at the padding above. Return adds a line; the control sends.
    private var editor: some View {
      TextField(
        "", text: $text,
        prompt: Text(placeholder).foregroundStyle(LLA.Color.muted), axis: .vertical
      )
      .textFieldStyle(.plain)
      .font(LLAFont.composer)
      .foregroundStyle(LLA.Color.ink)
      .lineLimit(1...3)
      .focused(focused)
      .onSubmit(onSubmit)
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
        Text(text.isEmpty ? " " : text + " ")
          .font(LLAFont.composer)
          .padding(.horizontal, 5)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
          .hidden()
          .accessibilityHidden(true)
          .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { editorHeight = $0 }
        if text.isEmpty {
          Text(placeholder)
            .font(LLAFont.composer)
            .foregroundStyle(LLA.Color.muted)
            .padding(.horizontal, 5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        TextEditor(text: $text)
          .font(LLAFont.composer)
          .foregroundStyle(LLA.Color.ink)
          .scrollContentBackground(.hidden)
          .scrollIndicators(.never)
          .focused(focused)
          .accessibilityLabel(placeholder)
          .accessibilityIdentifier("composer")
      }
      .frame(height: min(max(editorHeight, lineHeight), lineHeight * 3))
      .padding(.leading, -5)
    }
  #endif
}
