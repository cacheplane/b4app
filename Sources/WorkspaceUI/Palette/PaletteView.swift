import SwiftUI
import WorkspaceProtocol

/// The palette: Find and Commands in one place. A floating card on the Mac (⌘K, ⇧⌘P), a sheet on
/// the iPhone. It reads the model and runs catalog commands; the drafts behind it are never touched,
/// and closing it puts the cursor back in the composer.
struct PaletteView: View {
  @Bindable var model: WorkspaceModel
  @State private var palette: PaletteModel

  /// On the Mac: the card alone, for a panel of its own (`FloatingPanel`), with no scrim around it.
  private var floating = false

  /// `palette` is given only by a harness that needs to put the palette in a state before drawing it.
  init(model: WorkspaceModel, palette: PaletteModel? = nil, floating: Bool = false) {
    self.model = model
    self.floating = floating
    _palette = State(
      initialValue: palette ?? PaletteModel(workspace: model, purpose: model.palettePurpose))
  }

  var body: some View {
    Group {
      #if os(macOS)
        MacPalette(model: model, palette: palette, floating: floating)
      #else
        PhonePalette(model: model, palette: palette)
      #endif
    }
    .accessibilityIdentifier("search-palette")
    .onAppear {
      palette.onFinish = { spoken in
        AccessibilityNotification.Announcement(spoken).post()
        model.dismissPalette()
      }
    }
    // ⌘K or ⇧⌘P while it is open moves it to that purpose.
    .onChange(of: model.paletteRequest) { palette.show(model.palettePurpose) }
    .onChange(of: palette.feedback) { _, feedback in
      switch feedback {
      case .failed(let text), .unknown(let text): AccessibilityNotification.Announcement(text).post()
      case .requested, nil: break
      }
    }
  }
}

/// A title with its matched characters in the strong face: the palette's only emphasis.
struct MatchedTitle: View {
  let title: String
  let matched: Set<Int>
  var font: Font = LLAFont.row
  var strong: Font = LLAFont.rowStrong

  var body: some View {
    FuzzyMatch.runs(of: title, matched: matched).reduce(Text("")) { text, run in
      text + Text(run.text).font(run.matched ? strong : font)
    }
  }
}

/// A row's leading slot: a thread's mark, a command's symbol in the ghost colour, or the typed slash.
struct PaletteLead: View {
  let item: PaletteItem
  var selected = false

  var body: some View {
    Group {
      if let state = item.state {
        ThreadMark(state: state, acknowledged: item.acknowledged)
      } else if item.isSlash {
        Text("/").font(LLAFont.code)
      } else if let symbol = item.symbol {
        Image(systemName: symbol).font(.system(size: 12, weight: .light))
      }
    }
    .foregroundStyle(selected ? LLA.Color.muted : LLA.Color.ghost)
    .frame(width: LLA.Space.l, height: LLA.Space.l)
    .accessibilityHidden(true)
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

  struct MacPalette: View {
    @Bindable var model: WorkspaceModel
    let palette: PaletteModel
    /// In a panel of its own: the card alone, which the panel places and the owner can drag.
    var floating = false
    @FocusState private var focused: Bool
    @State private var selection: TextSelection?
    @State private var pointer = PointerTracker()
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 600
    static let rowHeight: CGFloat = 32
    /// Eight rows and their section labels fit before the list scrolls.
    static let listMaxHeight: CGFloat = 344
    /// The card at its tallest (the field, the list, the footer, and a notice's line), which is the
    /// room its panel gives it.
    static let fullHeight: CGFloat = 48 + 1 + listMaxHeight + 1 + LLA.Space.xxl + 48
    /// The field's row, which sits over the title bar's button when the palette opens there.
    static let fieldHeight: CGFloat = 48
    /// Where the card's top sits under the window's top.
    static let topOffset: CGFloat = 96

    @ViewBuilder var body: some View {
      if floating { card.frame(width: Self.width) } else { inWindow }
    }

    /// Inside the window, over a scrim: how a view without panels (a snapshot) shows it.
    private var inWindow: some View {
      ZStack(alignment: .top) {
        LLA.Color.ink.opacity(0.18)
          .ignoresSafeArea()
          .contentShape(Rectangle())
          .onTapGesture { model.dismissPalette() }
          .accessibilityHidden(true)
          .transition(.opacity)
        card
          .frame(maxWidth: Self.width)
          .padding(.top, Self.topOffset)
          .padding(.horizontal, LLA.Space.l)
          .transition(
            reduceMotion
              ? .opacity
              : .opacity.combined(with: .scale(scale: 0.985, anchor: .top)).combined(with: .offset(y: -6)))
      }
    }

    private var query: Binding<String> {
      Binding(get: { palette.query }, set: { palette.setQuery($0) })
    }

    private var card: some View {
      VStack(spacing: 0) {
        input
        if !isTextPage {
          Hairline()
          list
        }
        Hairline()
        footer
      }
      .background(LLA.Color.bg, in: RoundedRectangle(cornerRadius: LLA.Radius.card, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: LLA.Radius.card, style: .continuous).strokeBorder(LLA.Color.rule)
      )
      .clipShape(RoundedRectangle(cornerRadius: LLA.Radius.card, style: .continuous))
      // In a panel the window draws the shadow, and the panel takes each new height at once: an
      // animated height would leave the window, and its shadow, a step behind the card.
      .shadow(
        color: LLA.Color.ink.opacity(floating ? 0 : 0.12), radius: floating ? 0 : 18, x: 0,
        y: floating ? 0 : 8
      )
      .animation(floating ? nil : pageAnimation, value: palette.page)
      .accessibilityElement(children: .contain)
      .accessibilityLabel(palette.purpose.title)
      .onAppear { focused = true }
      .onChange(of: palette.page) { _, page in
        focused = true
        // A text argument opens with its text selected, ready to replace.
        if case .text = page {
          let text = palette.query
          selection = TextSelection(range: text.startIndex..<text.endIndex)
        }
      }
    }

    private var isTextPage: Bool {
      if case .text = palette.page { return true }
      return false
    }

    private var pageAnimation: Animation? {
      reduceMotion ? .linear(duration: 0.08) : .snappy(duration: 0.14, extraBounce: 0)
    }

    // MARK: Field

    private var input: some View {
      HStack(spacing: LLA.Space.s) {
        let crumbs = palette.crumbs
        if crumbs.isEmpty {
          Image(systemName: "magnifyingglass").foregroundStyle(LLA.Color.muted).accessibilityHidden(true)
        }
        ForEach(Array(crumbs.enumerated()), id: \.offset) { _, crumb in
          // A long title is cut inside its chip; the chip never takes more than it needs.
          Text(crumb)
            .font(LLAFont.caption).foregroundStyle(LLA.Color.muted).lineLimit(1)
            .padding(.horizontal, LLA.Space.s).padding(.vertical, 3)
            .background(Capsule().fill(LLA.Color.surfaceRaised))
            .frame(maxWidth: 200)
            .fixedSize(horizontal: true, vertical: false)
          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold)).foregroundStyle(LLA.Color.muted)
            .accessibilityHidden(true)
        }
        TextField(palette.placeholder, text: query, selection: $selection)
          .textFieldStyle(.plain)
          .font(LLAFont.body)
          .foregroundStyle(LLA.Color.ink)
          .focused($focused)
          .onSubmit {
            Task { await palette.activate() }
            focused = true
          }
          .onKeyPress(.downArrow) { move(1) }
          .onKeyPress(.upArrow) { move(-1) }
          .onKeyPress(.escape) {
            back()
            return .handled
          }
          .onKeyPress(keys: [.tab]) { press in
            if press.modifiers.contains(.shift) { back() } else { palette.showActions() }
            return .handled
          }
          // Backspace arrives as U+0008 or, from the Mac's keyboard, as U+007F.
          .onKeyPress(keys: [.delete, KeyEquivalent("\u{7F}")]) { _ in
            palette.deleteBackward() ? .handled : .ignored
          }
          .accessibilityLabel(palette.purpose.title)
          .accessibilityIdentifier("palette-field")
        Text("esc").font(LLAFont.codeSmall).foregroundStyle(LLA.Color.muted).accessibilityHidden(true)
      }
      .padding(.horizontal, LLA.Space.l)
      .frame(minHeight: 48)
      .background { if floating { WindowDragArea() } }
    }

    /// Escape and ⇧Tab: one level back, then close.
    private func back() {
      if !palette.back() { model.dismissPalette() }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
      withAnimation(reduceMotion ? nil : .snappy(duration: 0.09, extraBounce: 0)) {
        scrollTarget = palette.move(by: delta)
      }
      return .handled
    }

    @State private var scrollTarget: String?

    // MARK: List

    private var list: some View {
      let sections = palette.sections
      let selected = palette.selected?.id
      return ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            if let notice = emptyNotice(sections) { notice }
            ForEach(sections) { section in
              if let title = section.title {
                Text(title).llaSmallMuted().lineLimit(1)
                  .padding(.horizontal, LLA.Space.s).padding(.top, LLA.Space.s).padding(.bottom, LLA.Space.xs)
                  .accessibilityAddTraits(.isHeader)
              }
              ForEach(section.items) { item in row(item, selected: item.id == selected) }
            }
          }
          .padding(LLA.Space.s)
          .id(palette.page)
          .transition(
            reduceMotion
              ? .opacity
              : .asymmetric(
                insertion: .offset(x: palette.direction == .forward ? 10 : -10).combined(with: .opacity),
                removal: .identity))
        }
        .frame(maxHeight: Self.listMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: scrollTarget) { _, target in
          if let target { proxy.scrollTo(target) }
        }
      }
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
      Button {
        palette.select(item.id)
        Task { await palette.activate() }
      } label: {
        HStack(spacing: LLA.Space.s) {
          PaletteLead(item: item, selected: selected)
          MatchedTitle(
            title: item.title, matched: item.matched,
            font: item.isCode ? LLAFont.code : item.isActLevel ? LLAFont.rowMedium : LLAFont.row,
            strong: item.isCode ? LLAFont.mono(LLAFont.scale.code, weight: .semibold) : LLAFont.rowStrong
          )
          .foregroundStyle(
            item.isDestructive ? LLA.Color.danger : item.isAvailable ? LLA.Color.ink : LLA.Color.muted
          )
          .lineLimit(1)
          .layoutPriority(1)
          if let secondary = item.secondary {
            Text(secondary).llaCaption().lineLimit(1)
          }
          Spacer(minLength: LLA.Space.s)
          if let trailing = item.trailing {
            Text(trailing).llaCaption().lineLimit(1).fixedSize()
          }
          if item.isCurrent {
            Text("Current").llaCaption().fixedSize()
            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
              .foregroundStyle(LLA.Color.ink).accessibilityHidden(true)
          }
          if let shortcut = item.shortcut {
            Text(shortcut).font(LLAFont.codeSmall).foregroundStyle(LLA.Color.muted).fixedSize()
          }
        }
        .padding(.horizontal, LLA.Space.s)
        .frame(height: Self.rowHeight)
        .background {
          if selected {
            RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous)
              .fill(LLA.Color.surfaceRaised)
              .matchedGeometryEffect(id: "selection", in: highlight)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .id(item.id)
      // The pointer selects at once, with no slide, and only when it is the pointer that moved.
      .onContinuousHover(coordinateSpace: .global) { phase in
        if case .active(let point) = phase, pointer.moved(to: point) { palette.select(item.id) }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(item.spoken)
      .accessibilityHint(item.isAvailable ? item.primary : "")
      .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
      .accessibilityIdentifier("palette-row")
    }

    /// What is searchable, said once: when nothing matched, or before there is any thread.
    private func emptyNotice(_ sections: [PaletteSection]) -> PaletteNotice? {
      PaletteNotice.for(palette: palette, sections: sections)
    }

    // MARK: Footer

    private var footer: some View {
      HStack(spacing: LLA.Space.l) {
        HStack(spacing: LLA.Space.s) {
          if palette.running, case .requested = palette.feedback {
            ProgressView().controlSize(.mini).accessibilityHidden(true)
          }
          Text(palette.context)
            .font(LLAFont.caption)
            .foregroundStyle(isFailure ? LLA.Color.danger : LLA.Color.muted)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("palette-context")
        if palette.canShowActions {
          hint("Actions", key: "\u{21E5}") { palette.showActions() }
        } else if palette.depth > 1 {
          hint("Back", key: "\u{21E7}\u{21E5}") { back() }
        }
        Button {
          Task { await palette.activate() }
        } label: {
          HStack(spacing: LLA.Space.s) {
            Text(palette.primaryLabel).font(LLAFont.caption).foregroundStyle(LLA.Color.ink).lineLimit(1)
            Text("\u{21A9}").font(LLAFont.codeSmall).foregroundStyle(LLA.Color.muted)
          }
        }
        .buttonStyle(.plain)
        .disabled(!palette.primaryEnabled)
        .opacity(palette.primaryEnabled ? 1 : 0.45)
        .accessibilityLabel(palette.primaryLabel)
        .accessibilityIdentifier("palette-primary")
      }
      .padding(.horizontal, LLA.Space.l)
      .frame(height: LLA.Space.xxl)
      .background { if floating { WindowDragArea() } }
    }

    private var isFailure: Bool {
      if case .failed = palette.feedback { return true }
      return false
    }

    private func hint(_ title: String, key: String, action: @escaping () -> Void) -> some View {
      Button(action: action) {
        HStack(spacing: LLA.Space.s) {
          Text(title).font(LLAFont.caption)
          Text(key).font(LLAFont.codeSmall)
        }
        .foregroundStyle(LLA.Color.muted)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(title)
    }
  }
#endif

/// The words above the rows when there is nothing, or nearly nothing, to list.
struct PaletteNotice: View {
  let title: String
  let text: String

  /// "No matches" when a typed query found nothing of its own; "No threads yet" for an empty Find.
  static func `for`(palette: PaletteModel, sections: [PaletteSection]) -> PaletteNotice? {
    let items = sections.flatMap(\.items)
    let typed = !palette.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let onlyMessage = items.count == 1 && items[0].kind == .command(.useAsMessage, .workspace)
    if typed, items.isEmpty || onlyMessage {
      let scope =
        palette.page == .root(.find)
        ? "Search covers thread titles, environments, connections, settings, and commands. It does not search inside transcripts."
        : "Nothing here matches. Clear the text to see everything."
      return PaletteNotice(title: "No matches", text: scope)
    }
    if !typed, palette.page == .root(.find), palette.workspace.threads.isEmpty {
      return PaletteNotice(
        title: palette.workspace.link == .connecting ? "Loading threads\u{2026}" : "No threads yet",
        text:
          "Threads you start appear here. Environments, connections, settings, and commands are searchable now."
      )
    }
    return nil
  }

  var body: some View {
    VStack(spacing: LLA.Space.xs) {
      Text(title).font(LLAFont.smallStrong).foregroundStyle(LLA.Color.ink)
      Text(text).llaCaption().multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, LLA.Space.xl)
    .padding(.vertical, LLA.Space.l)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("palette-notice")
  }
}

#if os(iOS)
  /// The iPhone's palette: one list in a sheet. A tap runs a row's primary action; a thread's
  /// trailing button shows its actions; arguments are further lists, or a field for a title.
  struct PhonePalette: View {
    @Bindable var model: WorkspaceModel
    let palette: PaletteModel
    @FocusState private var titleFocused: Bool

    private var query: Binding<String> {
      Binding(get: { palette.query }, set: { palette.setQuery($0) })
    }

    private var isTextPage: Bool {
      if case .text = palette.page { return true }
      return false
    }

    /// The field's prompt. Find's own is too long for a phone's width and would be cut mid-word.
    private var prompt: String {
      palette.page == .root(.find) ? "Threads, environments, commands" : palette.placeholder
    }

    private var title: String {
      palette.crumbs.last ?? (palette.purpose == .find ? "Search" : "Commands")
    }

    var body: some View {
      NavigationStack {
        content
          .navigationTitle(title)
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              if palette.depth > 1 {
                Button("Back", systemImage: "chevron.backward") { palette.back() }
                  .accessibilityIdentifier("palette-back")
              } else {
                Button("Cancel") { model.dismissPalette() }
              }
            }
            ToolbarItem(placement: .confirmationAction) {
              if isTextPage {
                Button(palette.primaryLabel) { Task { await palette.activate() } }
                  .disabled(!palette.primaryEnabled)
                  .accessibilityIdentifier("palette-primary")
              } else if palette.depth == 1 {
                Button(palette.purpose == .find ? "Commands" : "Search") {
                  palette.show(palette.purpose == .find ? .commands : .find)
                }
                .accessibilityIdentifier("palette-purpose")
              }
            }
          }
      }
    }

    @ViewBuilder private var content: some View {
      if isTextPage {
        // The same plain page as the rows, with the field on the app's own surface.
        List {
          TextField(palette.placeholder, text: query)
            .font(LLAFont.row)
            .focused($titleFocused)
            .submitLabel(.done)
            .onSubmit { Task { await palette.activate() } }
            .accessibilityIdentifier("palette-field")
            .padding(.horizontal, LLA.Space.m)
            .frame(minHeight: 44)
            .background(
              LLA.Color.surface, in: RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous)
            )
            .listRowInsets(
              EdgeInsets(top: LLA.Space.s, leading: LLA.Space.l, bottom: 0, trailing: LLA.Space.l)
            )
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
          footnote.listRowSeparator(.hidden).listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(LLA.Color.bg)
        .onAppear { titleFocused = true }
      } else {
        rows
          .searchable(
            text: query, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt
          )
          .onSubmit(of: .search) { Task { await palette.activate() } }
      }
    }

    private var rows: some View {
      let sections = palette.sections
      return List {
        if let notice = PaletteNotice.for(palette: palette, sections: sections) {
          notice.listRowSeparator(.hidden).listRowBackground(Color.clear)
        }
        ForEach(sections) { section in
          Section {
            ForEach(section.items) { item in
              row(item)
                .listRowInsets(EdgeInsets(top: 0, leading: LLA.Space.l, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
          } header: {
            if let title = section.title { Text(title).llaSmallMuted().textCase(nil) }
          }
        }
        if !palette.context.isEmpty, palette.depth > 1 || palette.feedback != nil {
          footnote.listRowSeparator(.hidden).listRowBackground(Color.clear)
        }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .background(LLA.Color.bg)
    }

    private func row(_ item: PaletteItem) -> some View {
      HStack(spacing: LLA.Space.m) {
        Button {
          palette.select(item.id)
          Task { await palette.activate() }
        } label: {
          HStack(spacing: LLA.Space.m) {
            PaletteLead(item: item)
            VStack(alignment: .leading, spacing: 0) {
              MatchedTitle(
                title: item.title, matched: item.matched,
                font: item.isActLevel ? LLAFont.rowMedium : LLAFont.row
              )
              .foregroundStyle(
                item.isDestructive ? LLA.Color.danger : item.isAvailable ? LLA.Color.ink : LLA.Color.muted
              )
              .lineLimit(2)
              if let line = item.availability.reason ?? item.secondary {
                Text(line).llaSmallMuted().lineLimit(2)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let trailing = item.trailing, item.state == nil {
              Text(trailing).llaSmallMuted().lineLimit(1)
            }
            if item.isCurrent {
              Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(LLA.Color.ink)
                .accessibilityHidden(true)
            }
          }
          .padding(.vertical, 6)
          .padding(.trailing, item.hasActions ? 0 : LLA.Space.l)
          .frame(minHeight: LLA.Metrics.row)
          .contentShape(Rectangle())
        }
        .buttonStyle(.llaRow)
        .disabled(!item.isAvailable || palette.running)
        .accessibilityLabel(item.spoken)
        .accessibilityHint(item.isAvailable ? item.primary : "")
        .accessibilityIdentifier("palette-row")
        if item.hasActions {
          Button("Actions for \(item.title)", systemImage: "ellipsis") {
            palette.select(item.id)
            palette.showActions()
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .tint(LLA.Color.muted)
          .frame(width: LLA.Metrics.control, height: LLA.Metrics.control, alignment: .trailing)
          .padding(.trailing, LLA.Space.l)
          .accessibilityIdentifier("palette-actions")
        }
      }
    }

    /// When a change applies, or how the last command ended.
    private var footnote: some View {
      HStack(alignment: .firstTextBaseline, spacing: LLA.Space.s) {
        if palette.running { ProgressView().controlSize(.mini).accessibilityHidden(true) }
        Text(palette.context)
          .font(LLAFont.caption)
          .foregroundStyle(isFailure ? LLA.Color.danger : LLA.Color.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("palette-context")
    }

    private var isFailure: Bool {
      if case .failed = palette.feedback { return true }
      return false
    }
  }
#endif
