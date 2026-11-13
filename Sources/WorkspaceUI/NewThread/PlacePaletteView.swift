import SwiftUI
import WorkspaceProtocol

#if os(macOS)
  /// Where a new thread starts, on the Mac (the thread list and environments design, "Starting a
  /// thread"): a palette centred over the veiled main view. A "Start in…" filter, one row per
  /// environment (and per folder of one with several) with its path at the right, and a footer with
  /// "Choose folder… ⌘O" and "No folder". Up and Down (or the pointer) move one sliding highlight,
  /// Return chooses it, Escape closes. The new-thread view hosts it, the veil, and the folder panel.
  struct PlacePaletteView: View {
    @Bindable var model: WorkspaceModel
    let draft: NewThreadDraft
    let close: () -> Void
    let chooseFolder: () -> Void
    @State private var filter = ""
    @State private var highlighted = 0
    /// The highlighted row, so the highlight stays on it when the rows change under the palette.
    @State private var highlightedId: String?
    /// The arrow keys moved the highlight: a row sliding under a resting pointer must not take it back.
    @State private var keysMoved = false
    @State private var pointer: CGPoint?
    @FocusState private var focused: Bool
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// In a panel of its own the window draws the shadow.
    @Environment(\.isInFloatingPanel) private var inPanel

    static let width: CGFloat = 420
    static let radius: CGFloat = 14
    static let rowHeight: CGFloat = 36
    static let fieldHeight: CGFloat = 40
    static let footerHeight: CGFloat = 48
    static let listInset: CGFloat = 6
    /// The list scrolls past about five rows.
    static let listMaxHeight: CGFloat = rowHeight * 5 + listInset * 2
    /// The palette at its tallest. The host gives it this much room, top-aligned, so its field stays
    /// put while the filter shortens the list.
    static let fullHeight: CGFloat = fieldHeight + 1 + listMaxHeight + 1 + footerHeight

    private var rows: [PlacePalette.Row] {
      PlacePalette.rows(draft.environments, filter: filter, place: draft.palettePlace)
    }

    var body: some View {
      let rows = self.rows
      VStack(spacing: 0) {
        field(rows)
        Hairline()
        list(rows)
        Hairline()
        footer
      }
      .frame(width: Self.width)
      .background(LLA.Color.bg)
      .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(LLA.Color.rule)
      )
      .shadow(
        color: LLA.Color.ink.opacity(inPanel ? 0 : 0.12), radius: inPanel ? 0 : 18, x: 0, y: inPanel ? 0 : 8
      )
      .onAppear {
        highlighted = PlacePalette.initialHighlight(rows)
        highlightedId = rows.indices.contains(highlighted) ? rows[highlighted].id : nil
        focused = true
      }
      .onChange(of: filter) {
        // Typing counts as a key move: a row sliding under a resting pointer does not take the highlight.
        keysMoved = true
        let rows = self.rows
        highlighted = PlacePalette.initialHighlight(rows)
        highlightedId = rows.indices.contains(highlighted) ? rows[highlighted].id : nil
      }
      // An environment came, went or changed while the palette is open: the highlight keeps its row.
      .onChange(of: rows.map(\.id)) {
        let rows = self.rows
        highlighted = PlacePalette.highlight(highlighted, keeping: highlightedId, in: rows)
        // When its row is gone the highlight is on another now; remember that one. An empty list
        // keeps the old id, for when the rows come back.
        if rows.indices.contains(highlighted) { highlightedId = rows[highlighted].id }
      }
      .onExitCommand { close() }
      .accessibilityElement(children: .contain)
      .accessibilityAddTraits(.isModal)
      .accessibilityLabel("Start in")
      .accessibilityAction(.escape) { close() }
      .accessibilityIdentifier("place-palette")
    }

    private func field(_ rows: [PlacePalette.Row]) -> some View {
      TextField("Start in…", text: $filter)
        .textFieldStyle(.plain)
        .font(LLAFont.sans(15, relativeTo: .body))
        .foregroundStyle(LLA.Color.ink)
        .focused($focused)
        .onSubmit { if rows.indices.contains(highlighted) { choose(rows[highlighted]) } }
        .onKeyPress(.downArrow) {
          keysMoved = true
          withAnimation(SelectionMotion.animation(reduceMotion: reduceMotion)) {
            highlighted = PlacePalette.step(highlighted, by: 1, count: rows.count)
          }
          return .handled
        }
        .onKeyPress(.upArrow) {
          keysMoved = true
          withAnimation(SelectionMotion.animation(reduceMotion: reduceMotion)) {
            highlighted = PlacePalette.step(highlighted, by: -1, count: rows.count)
          }
          return .handled
        }
        .onKeyPress(.escape) {
          close()
          return .handled
        }
        .padding(.horizontal, LLA.Space.l)
        .frame(height: Self.fieldHeight)
        .accessibilityLabel("Filter")
        .accessibilityIdentifier("place-filter")
    }

    @ViewBuilder private func list(_ rows: [PlacePalette.Row]) -> some View {
      if rows.isEmpty {
        Text(PlacePalette.emptyLine(filter: filter, canChooseFolder: !model.relaysThroughHub))
          .font(LLAFont.small)
          .foregroundStyle(LLA.Color.muted)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, LLA.Space.l)
          .frame(height: Self.rowHeight + Self.listInset * 2)
          .accessibilityIdentifier("place-empty")
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(spacing: 0) {
              ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                rowView(row, highlighted: index == highlighted)
                  .id(row.id)
                  .onContinuousHover(coordinateSpace: .global) { phase in
                    guard case .active(let location) = phase else { return }
                    // After a key move, only a pointer that itself moved takes the highlight.
                    let moved = pointer.map { $0 != location } ?? !keysMoved
                    pointer = location
                    guard moved else { return }
                    keysMoved = false
                    withAnimation(SelectionMotion.animation(reduceMotion: reduceMotion)) {
                      highlighted = index
                    }
                  }
              }
            }
            .padding(Self.listInset)
          }
          .frame(height: min(CGFloat(rows.count) * Self.rowHeight + Self.listInset * 2, Self.listMaxHeight))
          .onChange(of: highlighted) { _, index in
            guard rows.indices.contains(index) else { return }
            highlightedId = rows[index].id
            proxy.scrollTo(rows[index].id)
          }
        }
      }
    }

    private func rowView(_ row: PlacePalette.Row, highlighted: Bool) -> some View {
      Button {
        choose(row)
      } label: {
        HStack(spacing: LLA.Space.s) {
          Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(LLA.Color.ink)
            .opacity(row.checked ? 1 : 0)
            .frame(width: 12)
            .accessibilityHidden(true)
          Text(row.title)
            .font(LLAFont.sans(14, relativeTo: .body))
            .foregroundStyle(LLA.Color.ink)
            .lineLimit(1)
          Spacer(minLength: LLA.Space.m)
          if let path = row.path {
            Text(PlacePalette.shownPath(path))
              .font(LLAFont.mono(11, relativeTo: .caption))
              .foregroundStyle(LLA.Color.muted)
              .lineLimit(1)
              .truncationMode(.head)
          }
        }
        .padding(.leading, row.indented ? 10 + 20 : 10)
        .padding(.trailing, 10)
        .frame(height: Self.rowHeight)
        .selectionHighlight(highlighted, in: highlight)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(row.title)
      .accessibilityValue(row.path.map { PlacePalette.shownPath($0) } ?? "")
      .accessibilityHint(row.indented ? "In \(row.environmentName)" : "")
      .accessibilityAddTraits(row.checked ? .isSelected : [])
      .accessibilityIdentifier("place-row-\(row.id)")
    }

    private var footer: some View {
      HStack(spacing: LLA.Space.s) {
        Button {
          close()
          chooseFolder()
        } label: {
          HStack(spacing: 6) {
            Text("Choose folder…")
            Text("⌘O").foregroundStyle(LLA.Color.muted)
          }
        }
        .keyboardShortcut("o", modifiers: .command)
        // A Mac that relays through the hub cannot browse its folders here.
        .disabled(model.relaysThroughHub)
        .accessibilityIdentifier("choose-folder")
        Button("No folder") {
          draft.selectNoFolder()
          close()
        }
        .accessibilityAddTraits(draft.isNoFolder ? .isSelected : [])
        .accessibilityIdentifier("no-folder")
        Spacer(minLength: LLA.Space.s)
        Text("esc to close")
          .font(LLAFont.caption)
          .foregroundStyle(LLA.Color.muted)
          .fixedSize()
      }
      .buttonStyle(FooterButtonStyle())
      .padding(.horizontal, LLA.Space.m)
      .frame(height: Self.footerHeight)
      .background(LLA.Color.surface)
    }

    private func choose(_ row: PlacePalette.Row) {
      draft.choose(row)
      close()
    }
  }

  /// The footer's two actions: equal bordered buttons on the window colour.
  private struct FooterButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .font(LLAFont.small)
        .foregroundStyle(LLA.Color.ink)
        .lineLimit(1)
        .frame(width: 136, height: 28)
        .background(
          RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous)
            .fill(configuration.isPressed ? LLA.Color.surfaceRaised : LLA.Color.bg)
        )
        .overlay(
          RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous).strokeBorder(LLA.Color.rule)
        )
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.45)
    }
  }
#else
  /// Where a new thread starts, on the phone: the palette's list as a sheet, without "Choose folder…"
  /// (the phone cannot browse the Mac), then "No folder".
  struct PlaceSheet: View {
    let draft: NewThreadDraft
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
      let rows = PlacePalette.rows(draft.environments, filter: "", place: draft.palettePlace)
      NavigationStack {
        List {
          if !rows.isEmpty {
            Section {
              ForEach(rows) { row in
                choice(row.title, checked: row.checked, indented: row.indented) {
                  draft.choose(row)
                }
                .accessibilityHint(row.indented ? "In \(row.environmentName)" : "")
                .accessibilityIdentifier("place-row-\(row.id)")
              }
            }
          }
          Section {
            choice("No folder", checked: draft.isNoFolder, indented: false) { draft.selectNoFolder() }
              .accessibilityIdentifier("no-folder")
          }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, LLA.Metrics.row)
        .background(LLA.Color.bg)
        .navigationTitle("Start in")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
      }
      .presentationDetents([.medium, .large])
      .accessibilityIdentifier("place-sheet")
    }

    private func choice(
      _ title: String, checked: Bool, indented: Bool, action: @escaping () -> Void
    ) -> some View {
      Button {
        action()
        dismiss()
      } label: {
        HStack(spacing: LLA.Space.s) {
          Text(title).font(LLAFont.row).foregroundStyle(LLA.Color.ink)
            // At the accessibility sizes a long name wraps instead of being cut to one line.
            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
          Spacer(minLength: LLA.Space.s)
          if checked {
            Image(systemName: "checkmark").foregroundStyle(LLA.Color.ink).accessibilityHidden(true)
          }
        }
        .padding(.leading, indented ? LLA.Space.l : 0)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(checked ? .isSelected : [])
    }
  }
#endif
