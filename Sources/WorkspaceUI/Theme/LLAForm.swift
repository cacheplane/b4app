import SwiftUI

// Forms in sheets (settings connections design): one grouped section of labelled rows, help in ⓘ
// popovers instead of paragraphs, and Cancel and the action at the bottom trailing edge.

/// Rows on the surface with a rule between them, in a 12 pt rounded group.
struct LLAFormGroup<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    VStack(spacing: 0) {
      Group(subviews: content) { rows in
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
          if index > 0 { Rectangle().fill(LLA.Color.rule).frame(height: 1) }
          row
        }
      }
    }
    .background(
      RoundedRectangle(cornerRadius: LLA.Radius.menu, style: .continuous).fill(LLA.Color.surface)
    )
    .overlay(
      RoundedRectangle(cornerRadius: LLA.Radius.menu, style: .continuous).strokeBorder(LLA.Color.rule)
    )
  }
}

/// A labelled row. On the Mac the label sits in a 96 pt leading column with the control 12 pt after it,
/// in a row at least 48 pt tall; on the phone, and at accessibility sizes, the label sits above.
struct LLAFormRow<Content: View>: View {
  let label: String
  var info: LLAInfo?
  @ViewBuilder var content: Content
  @Environment(\.dynamicTypeSize) private var typeSize

  /// 96: the label column (`xxl` + `xxl` + `l`), wide enough for "API key" with its ⓘ.
  static var labelWidth: CGFloat { LLA.Space.xxl * 2 + LLA.Space.l }

  var body: some View {
    if stacked {
      VStack(alignment: .leading, spacing: LLA.Space.xs) {
        title.font(LLAFont.caption).foregroundStyle(LLA.Color.muted)
        content
      }
      .frame(maxWidth: .infinity, minHeight: LLA.Metrics.row, alignment: .leading)
      .padding(.horizontal, LLA.Space.l)
      .padding(.vertical, LLA.Space.s)
    } else {
      HStack(spacing: LLA.Space.m) {
        title.font(LLAFont.small).foregroundStyle(LLA.Color.ink)
          .frame(width: Self.labelWidth, alignment: .leading)
        content.frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(minHeight: 48)
      .padding(.horizontal, LLA.Space.m)
    }
  }

  private var stacked: Bool {
    #if os(iOS)
      true
    #else
      typeSize.isAccessibilitySize
    #endif
  }

  private var title: some View {
    HStack(spacing: LLA.Space.xs) {
      Text(label).lineLimit(stacked ? nil : 1)
      if let info { LLAInfoButton(info: info) }
    }
  }
}

/// What an ⓘ says: one or two sentences, and where "Learn more" goes.
struct LLAInfo: Sendable {
  let text: String
  var learnMore: URL?
}

/// A small muted ⓘ that opens a popover with a sentence or two and "Learn more".
struct LLAInfoButton: View {
  let info: LLAInfo
  @State private var shown = false
  @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 14

  var body: some View {
    Button {
      shown.toggle()
    } label: {
      Image(systemName: "info.circle")
        .resizable()
        .frame(width: size, height: size)
        .foregroundStyle(LLA.Color.muted)
        .contentShape(Rectangle().inset(by: -LLA.Space.s))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("More information")
    .popover(isPresented: $shown, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: LLA.Space.s) {
        Text(info.text)
          .font(LLAFont.small)
          .foregroundStyle(LLA.Color.ink)
          .fixedSize(horizontal: false, vertical: true)
        if let url = info.learnMore {
          Link("Learn more", destination: url).font(LLAFont.small).tint(LLA.Color.accent)
        }
      }
      .padding(LLA.Space.m)
      .frame(width: 240, alignment: .leading)
      .presentationCompactAdaptation(.popover)
    }
  }
}

/// Cancel and the sheet's action at the bottom trailing edge, the action the default button.
struct LLASheetBar: View {
  let confirmTitle: String
  var disabled = false
  let cancel: () -> Void
  let confirm: () -> Void

  var body: some View {
    HStack(spacing: LLA.Space.s) {
      Spacer(minLength: 0)
      Button("Cancel", action: cancel).buttonStyle(.llaSecondary).keyboardShortcut(.cancelAction)
      Button(confirmTitle, action: confirm).buttonStyle(.llaPrimary).keyboardShortcut(.defaultAction)
        .disabled(disabled)
    }
  }
}

/// The text field forms use: the surface field from `LLAField`, in JetBrains Mono for addresses and
/// keys, optionally secure.
struct LLAFormField: View {
  let placeholder: String
  @Binding var text: String
  var mono = false
  var secure = false
  @FocusState private var focused: Bool

  var body: some View {
    Group {
      if secure {
        SecureField("", text: $text, prompt: prompt)
      } else {
        TextField("", text: $text, prompt: prompt)
      }
    }
    .textFieldStyle(.plain)
    .focused($focused)
    .font(mono ? LLAFont.code : LLAFont.small)
    // The Mac draws the prompt in the field's own style, so an empty field is muted (as the composer's
    // prompt is) and typing turns it ink.
    .foregroundStyle(text.isEmpty ? LLA.Color.muted : LLA.Color.ink)
    .autocorrectionDisabled()
    #if os(iOS)
      .textInputAutocapitalization(.never)
      .frame(minHeight: LLA.Metrics.control)
    #else
      .padding(.horizontal, LLA.Space.s)
      .frame(height: LLA.Metrics.control)
      .background(RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous).fill(LLA.Color.bg))
      .overlay(
        RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous)
          .strokeBorder(focused ? LLA.Color.accent : LLA.Color.rule, lineWidth: focused ? 2 : 1)
      )
    #endif
    .focusEffectDisabled()
  }

  private var prompt: Text { Text(placeholder).foregroundStyle(LLA.Color.muted) }
}
