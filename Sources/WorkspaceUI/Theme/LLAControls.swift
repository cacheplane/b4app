import SwiftUI

// Shared controls. Every view composes these instead of styling its own pills, cards, and labels.

/// Pill buttons: ink (primary), surface (secondary), danger text on surface, or a plain accent link.
/// Icons in labels are dropped; the LLA rules keep decoration out and the title carries the meaning.
public struct LLAButtonStyle: ButtonStyle {
  public enum Kind: Sendable { case primary, secondary, danger, link }

  public var kind: Kind

  public init(kind: Kind) { self.kind = kind }

  public func makeBody(configuration: Configuration) -> some View {
    PillLabel(kind: kind, configuration: configuration)
  }

  private struct PillLabel: View {
    let kind: Kind
    let configuration: Configuration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
      configuration.label
        .labelStyle(.titleOnly)
        .font(LLAFont.button)
        .lineLimit(1)
        .padding(.horizontal, kind == .link ? 0 : 14)
        // A link keeps its text's width but still gets a full-height target on the phone.
        .frame(minHeight: kind == .link ? LLA.Metrics.row : LLA.Metrics.control)
        .foregroundStyle(foreground)
        .background {
          if kind != .link { Capsule().fill(fill) }
        }
        .contentShape(Capsule())
        .opacity(configuration.isPressed ? 0.8 : 1)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
    }

    private var fill: Color {
      switch kind {
      case .primary: return LLA.Color.ink
      case .secondary, .danger: return hovering ? LLA.Color.surfaceRaised : LLA.Color.surface
      case .link: return .clear
      }
    }

    private var foreground: Color {
      switch kind {
      case .primary: return LLA.Color.bg
      case .secondary: return LLA.Color.ink
      case .danger: return LLA.Color.danger
      case .link: return hovering ? LLA.Color.accentHover : LLA.Color.accent
      }
    }
  }
}

extension ButtonStyle where Self == LLAButtonStyle {
  public static var llaPrimary: LLAButtonStyle { LLAButtonStyle(kind: .primary) }
  public static var llaSecondary: LLAButtonStyle { LLAButtonStyle(kind: .secondary) }
  public static var llaDanger: LLAButtonStyle { LLAButtonStyle(kind: .danger) }
  public static var llaLink: LLAButtonStyle { LLAButtonStyle(kind: .link) }
}

/// A bordered panel: 1 pt rule, radius 16, no shadow.
public struct LLACard<Content: View>: View {
  public enum Fill: Sendable { case bg, surface }

  public var fill: Fill
  public var padding: CGFloat
  @ViewBuilder public var content: () -> Content

  public init(fill: Fill = .bg, padding: CGFloat = LLA.Space.l, @ViewBuilder content: @escaping () -> Content)
  {
    self.fill = fill
    self.padding = padding
    self.content = content
  }

  public var body: some View {
    content()
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: LLA.Radius.card, style: .continuous)
          .fill(fill == .bg ? LLA.Color.bg : LLA.Color.surface)
      )
      .overlay(
        RoundedRectangle(cornerRadius: LLA.Radius.card, style: .continuous).stroke(
          LLA.Color.rule, lineWidth: 1))
  }
}

/// A 1 pt rule.
public struct Hairline: View {
  public init() {}
  public var body: some View { Rectangle().fill(LLA.Color.rule).frame(height: 1) }
}

/// A small pill of text. Never uppercase.
public struct LLABadge: View {
  public enum Tone: Sendable { case neutral, muted, accent, danger }

  public var text: String
  public var tone: Tone
  public var raised: Bool

  public init(_ text: String, tone: Tone = .muted, raised: Bool = false) {
    self.text = text
    self.tone = tone
    self.raised = raised
  }

  public var body: some View {
    Text(text)
      .font(LLAFont.caption)
      .foregroundStyle(color)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(Capsule().fill(raised ? LLA.Color.surfaceRaised : LLA.Color.surface))
  }

  private var color: Color {
    switch tone {
    case .neutral: return LLA.Color.ink
    case .muted: return LLA.Color.muted
    case .accent: return LLA.Color.accent
    case .danger: return LLA.Color.danger
    }
  }
}

/// Thread state as a dot (visual-system spec, "State colour"). The running ring is the one moving
/// element in a view; it holds still under Reduce Motion.
public struct LLAStateDot: View {
  public var state: ThreadRowState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var pulse = false

  public init(state: ThreadRowState) { self.state = state }

  public var body: some View {
    ZStack {
      if state == .running || state == .stopping {
        Circle().stroke(LLA.Color.ink.opacity(pulse ? 0.08 : 0.3), lineWidth: 1.5).frame(
          width: 14, height: 14)
      }
      if state == .unknown {
        Circle().stroke(LLA.Color.danger, lineWidth: 1.5).frame(width: 8, height: 8)
      } else {
        Circle().fill(fill).frame(width: 8, height: 8)
      }
    }
    .frame(width: 14, height: 14)
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true }
    }
    .accessibilityLabel(state.label)
  }

  private var fill: Color {
    switch state {
    case .idle: return LLA.Color.rule
    case .running, .stopping: return LLA.Color.ink
    case .waiting: return LLA.Color.accent
    case .unknown: return .clear
    case .reconnecting: return LLA.Color.muted
    case .error: return LLA.Color.danger
    }
  }
}

/// A section head: title plus an optional sentence. Replaces bold "headline" labels.
public struct LLASectionHead: View {
  public var title: String
  public var intro: String?

  public init(_ title: String, intro: String? = nil) {
    self.title = title
    self.intro = intro
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: LLA.Space.xs) {
      Text(title).llaTitle()
      if let intro { Text(intro).llaMuted().fixedSize(horizontal: false, vertical: true) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityAddTraits(.isHeader)
  }
}

/// An empty state: a heading, a sentence, and plain buttons. No illustration, no dark panel.
public struct LLAEmptyState<Actions: View>: View {
  public var title: String
  public var text: String
  @ViewBuilder public var actions: () -> Actions

  public init(_ title: String, text: String, @ViewBuilder actions: @escaping () -> Actions) {
    self.title = title
    self.text = text
    self.actions = actions
  }

  public var body: some View {
    // A scroll view, not a fill-the-column frame: inside a NavigationSplitView column an infinite
    // frame inflates the window's ideal height and the content lands outside the window.
    ScrollView {
      VStack(alignment: .leading, spacing: LLA.Space.m) {
        Text(title).llaDisplay()
        Text(text).llaMuted().fixedSize(horizontal: false, vertical: true)
        HStack(spacing: LLA.Space.s) { actions() }.padding(.top, LLA.Space.xs)
      }
      .frame(maxWidth: 440, alignment: .leading)
      .padding(LLA.Space.xxl)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

extension LLAEmptyState where Actions == EmptyView {
  public init(_ title: String, text: String) {
    self.init(title, text: text) { EmptyView() }
  }
}

/// A text field in the LLA shape: surface fill, rule border, radius 8, a 2 pt accent ring when focused.
public struct LLAField: View {
  public var title: String
  @Binding public var text: String
  public var secure: Bool
  @FocusState private var focused: Bool

  public init(_ title: String, text: Binding<String>, secure: Bool = false) {
    self.title = title
    self._text = text
    self.secure = secure
  }

  public var body: some View {
    Group {
      if secure {
        SecureField(title, text: $text)
      } else {
        TextField(title, text: $text)
      }
    }
    .textFieldStyle(.plain)
    .focused($focused)
    .font(LLAFont.body)
    .foregroundStyle(LLA.Color.ink)
    .padding(.horizontal, 10)
    .frame(minHeight: LLA.Metrics.control)
    .background(RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous).fill(LLA.Color.surface))
    .overlay(
      RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous)
        .stroke(focused ? LLA.Color.accent : LLA.Color.rule, lineWidth: focused ? 2 : 1)
    )
    .focusEffectDisabled()
  }
}

/// Label-and-value facts (Diagnostics, a runtime's status): a two-column grid, or each label above
/// its value at accessibility text sizes, where a label column would leave the value a sliver.
public struct LLAFacts<Rows: View>: View {
  @ViewBuilder public var rows: () -> Rows
  @Environment(\.dynamicTypeSize) private var typeSize

  public init(@ViewBuilder rows: @escaping () -> Rows) { self.rows = rows }

  public var body: some View {
    if typeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: LLA.Space.m) { rows() }
    } else {
      Grid(alignment: .leading, horizontalSpacing: LLA.Space.l, verticalSpacing: LLA.Space.xs) { rows() }
    }
  }
}

/// One fact in `LLAFacts`: a muted label and its value.
public struct LLAFact<Value: View>: View {
  public var label: String
  @ViewBuilder public var value: () -> Value
  @Environment(\.dynamicTypeSize) private var typeSize

  public init(_ label: String, @ViewBuilder value: @escaping () -> Value) {
    self.label = label
    self.value = value
  }

  public var body: some View {
    if typeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: 2) {
        Text(label).llaSmallMuted()
        value()
      }
    } else {
      GridRow {
        Text(label).llaSmallMuted()
        value()
      }
    }
  }
}

/// Monospaced output in an ink block, horizontally scrollable, selectable, never executed.
public struct LLACodeBlock: View {
  public var text: String
  public var maxHeight: CGFloat?

  public init(_ text: String, maxHeight: CGFloat? = 240) {
    self.text = text
    self.maxHeight = maxHeight
  }

  public var body: some View {
    ScrollView([.horizontal, .vertical]) {
      Text(text)
        .font(LLAFont.codeSmall)
        .foregroundStyle(LLA.Color.codeFg)
        .textSelection(.enabled)
        .padding(LLA.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxHeight: maxHeight)
    .background(RoundedRectangle(cornerRadius: LLA.Radius.card, style: .continuous).fill(LLA.Color.codeBg))
  }
}

extension View {
  /// The one shadow in the theme: a soft lift for panels that float over the window (the search
  /// palette, the profile menu). Cards and sheets stay flat.
  public func llaPopoverShadow() -> some View {
    shadow(color: LLA.Color.ink.opacity(0.12), radius: 18, x: 0, y: 8)
  }
}
