import SwiftUI
import WorkspaceProtocol

/// Thread search by title, for the palette.
enum ThreadSearch {
  /// The title a list row shows, which is what a search matches.
  static func shownTitle(_ thread: ConversationThread) -> String {
    thread.title.isEmpty ? "Untitled" : thread.title
  }

  /// Live threads in attention order, then archived ones, matching `query` in their shown title (case
  /// insensitive); an empty query lists live threads only. At most `limit`.
  static func results(in threads: [ConversationThread], query: String, limit: Int = 8) -> [ConversationThread]
  {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else {
      return Array(Attention.ordered(threads.filter { !$0.archived }).prefix(limit))
    }
    let matches = threads.filter { shownTitle($0).localizedCaseInsensitiveContains(needle) }
    let live = Attention.ordered(matches.filter { !$0.archived })
    let archived = Attention.ordered(matches.filter(\.archived))
    return Array((live + archived).prefix(limit))
  }

  /// Move a highlight by `delta`, staying inside `0..<count`.
  static func step(_ index: Int, by delta: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return min(max(index + delta, 0), count - 1)
  }
}

/// ⌘K: a field and up to eight threads. Up and Down move the highlight, Return opens it, Escape (or
/// a click outside on the Mac) closes. An overlay on the Mac, a sheet on the iPhone.
struct SearchPalette: View {
  @Bindable var model: WorkspaceModel
  @State private var query = ""
  @State private var highlighted = 0
  @FocusState private var focused: Bool
  @Environment(\.showDetail) private var showDetail

  init(model: WorkspaceModel) { self.model = model }

  private var results: [ConversationThread] { ThreadSearch.results(in: model.threads, query: query) }

  var body: some View {
    #if os(macOS)
      ZStack(alignment: .top) {
        LLA.Color.ink.opacity(0.18)
          .ignoresSafeArea()
          .contentShape(Rectangle())
          .onTapGesture { close() }
          .accessibilityHidden(true)
        card
          .frame(width: 560)
          .padding(.top, 96)
      }
      .accessibilityIdentifier("search-palette")
    #else
      NavigationStack {
        List {
          ForEach(Array(results.enumerated()), id: \.element.id) { index, thread in
            Button {
              open(thread)
            } label: {
              row(thread, highlighted: false)
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
          }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, LLA.Metrics.row)
        .background(LLA.Color.bg)
        .searchable(
          text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search threads"
        )
        .onSubmit(of: .search) { if let first = results.first { open(first) } }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { close() } }
        }
      }
      .accessibilityIdentifier("search-palette")
    #endif
  }

  #if os(macOS)
    private var card: some View {
      let results = self.results
      return VStack(spacing: 0) {
        HStack(spacing: LLA.Space.s) {
          Image(systemName: "magnifyingglass").foregroundStyle(LLA.Color.muted)
          TextField("Search threads", text: $query)
            .textFieldStyle(.plain)
            .font(LLAFont.body)
            .foregroundStyle(LLA.Color.ink)
            .focused($focused)
            .onSubmit { if results.indices.contains(highlighted) { open(results[highlighted]) } }
            .onKeyPress(.downArrow) {
              highlighted = ThreadSearch.step(highlighted, by: 1, count: results.count)
              return .handled
            }
            .onKeyPress(.upArrow) {
              highlighted = ThreadSearch.step(highlighted, by: -1, count: results.count)
              return .handled
            }
            .onKeyPress(.escape) {
              close()
              return .handled
            }
        }
        .padding(.horizontal, LLA.Space.l)
        .frame(minHeight: 48)
        if !results.isEmpty {
          Hairline()
          VStack(spacing: 2) {
            ForEach(Array(results.enumerated()), id: \.element.id) { index, thread in
              Button {
                open(thread)
              } label: {
                row(thread, highlighted: index == highlighted)
              }
              .buttonStyle(.plain)
              .onHover { if $0 { highlighted = index } }
            }
          }
          .padding(LLA.Space.s)
        }
      }
      .background(LLA.Color.bg, in: RoundedRectangle(cornerRadius: LLA.Radius.card, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: LLA.Radius.card, style: .continuous).strokeBorder(LLA.Color.rule)
      )
      .llaPopoverShadow()
      .onAppear { focused = true }
      .onChange(of: query) { highlighted = 0 }
    }
  #endif

  private func row(_ thread: ConversationThread, highlighted: Bool) -> some View {
    HStack(spacing: LLA.Space.s) {
      AttentionDot(band: model.band(of: thread))
      Text(ThreadSearch.shownTitle(thread))
        .font(LLAFont.row)
        .foregroundStyle(LLA.Color.ink)
        .lineLimit(1)
      if let project = model.projectName(for: thread) {
        Text(project).font(LLAFont.caption).foregroundStyle(LLA.Color.muted).lineLimit(1)
      }
      if thread.archived {
        Text("Archived").font(LLAFont.caption).foregroundStyle(LLA.Color.muted)
      }
      Spacer(minLength: LLA.Space.s)
      if let kind = model.connection(id: thread.connectionId)?.kind { RuntimeMark(kind: kind) }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .frame(minHeight: LLA.Metrics.row)
    .background(
      RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous)
        .fill(highlighted ? LLA.Color.surfaceRaised : .clear)
    )
    .contentShape(Rectangle())
  }

  private func open(_ thread: ConversationThread) {
    model.selectedThreadId = thread.id
    model.showSearch = false
    showDetail()
    Task { await model.openThread(id: thread.id) }
  }

  private func close() { model.showSearch = false }
}
