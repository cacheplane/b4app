import Observation
import SwiftUI
import WorkspaceProtocol

/// The composer's `/`: a slash typed as the first character of an empty draft lists the commands
/// that apply to this thread (or this new-thread draft), and Return picks one instead of sending.
/// Anything else that starts with a slash, a pasted path, a slash further in, a token no command
/// answers to, is the message it looks like.
@Observable
final class SlashController {
  enum State: Equatable {
    case closed
    /// Listing commands for the token typed so far.
    case commands
    /// Listing one command's values; the token has left the draft.
    case choices(CommandID)
  }

  struct Item: Identifiable, Equatable {
    var id: String
    /// "/model", in the mono face; nil for a value.
    var command: String?
    /// How many leading characters of `command` the typed token matched.
    var matchedPrefix = 0
    var title: String
    var trailing: String?
    var isCurrent = false
    var isAvailable = true
    var reason: String?
    var primary: String
    /// The title is the runtime's description of its command, drawn quieter than an app command's.
    var isRuntime = false
    /// The footer's words while a runtime command is selected.
    var note: String?
    fileprivate var action: Action
  }

  fileprivate enum Action: Equatable {
    case command(CommandID)
    case choice(String)
    case runtime(RuntimeCommand)
  }

  /// What the field's text should become after a key or a pick; nil leaves it alone.
  typealias TextChange = String?

  /// What a pick asks of the composer.
  enum Pick: Equatable {
    /// Replace the draft's text.
    case text(String)
    /// Send this text as the message now, or leave it in the draft when nothing can be sent yet.
    case send(String)
  }

  let workspace: WorkspaceModel
  var target: CommandTarget
  private(set) var state = State.closed
  /// The characters after the slash.
  private(set) var token = ""
  private(set) var selection: String?
  /// Why the last pick did nothing.
  private(set) var failure: String?
  private(set) var running = false

  init(workspace: WorkspaceModel, target: CommandTarget) {
    self.workspace = workspace
    self.target = target
  }

  /// A command token: a slash and then only letters, digits, and the marks command names use.
  static func isToken(_ text: String) -> Bool {
    guard text.first == "/" else { return false }
    return text.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ":" }
  }

  /// The draft changed. Completions open only on a slash typed into an empty draft, follow the
  /// token while it stays a token, and close on anything else.
  func textChanged(from old: String, to new: String) {
    if case .choices = state {
      // The token left the draft when its command was picked; typing a message closes the values.
      if !new.isEmpty { close() }
      return
    }
    guard Self.isToken(new) else {
      close()
      return
    }
    if state == .commands || (new == "/" && old.isEmpty) {
      state = .commands
      token = String(new.dropFirst()).lowercased()
      selection = nil
      failure = nil
    }
  }

  private func close() {
    state = .closed
    token = ""
    selection = nil
    failure = nil
  }

  var items: [Item] {
    switch state {
    case .closed: return []
    case .commands: return commandItems
    case .choices(let id):
      return workspace.choices(for: id, target: target).map { choice in
        Item(
          id: "choice:\(choice.id)", title: choice.title, trailing: choice.detail,
          isCurrent: choice.isCurrent,
          primary: choice.isCurrent ? "Keep \(choice.title)" : "Use \(choice.title)",
          action: .choice(choice.value))
      }
    }
  }

  /// Commands whose name or alias starts with the token, a name before an alias, in catalog order.
  private var commandItems: [Item] {
    var named: [Item] = []
    var aliased: [Item] = []
    for id in workspace.slashCommands(for: target) {
      let definition = CommandCatalog.definition(id)
      guard let name = definition.slash else { continue }
      let commandTarget: CommandTarget = id == .newThread ? .workspace : target
      let availability = workspace.availability(of: id, target: commandTarget)
      var item = Item(
        id: id.rawValue, command: "/\(name)",
        title: CommandCatalog.plain(workspace.title(of: id, target: commandTarget)),
        trailing: workspace.currentValue(of: id, target: commandTarget) ?? Self.shortcut(definition),
        isAvailable: availability == .available, reason: availability.reason,
        primary: workspace.primaryLabel(of: id, target: commandTarget), action: .command(id))
      if name.hasPrefix(token) {
        item.matchedPrefix = token.count + 1
        named.append(item)
      } else if definition.slashAliases.contains(where: { $0.hasPrefix(token) }) {
        aliased.append(item)
      }
    }
    return named + aliased + runtimeItems
  }

  /// The runtime's own commands after the app's: a name that starts with the token first, then a
  /// name whose part after a plugin's colon or whose alias does, then a name that contains it.
  private var runtimeItems: [Item] {
    guard let (connection, commands) = workspace.runtimeCommands(for: target) else { return [] }
    var ranks: [[Item]] = [[], [], []]
    for command in commands {
      let name = command.name
      let rank: Int
      if name.hasPrefix(token) {
        rank = 0
      } else if name.split(separator: ":").dropFirst().contains(where: { $0.hasPrefix(token) })
        || (command.aliases ?? []).contains(where: { $0.hasPrefix(token) })
      {
        rank = 1
      } else if name.contains(token) {
        rank = 2
      } else {
        continue
      }
      let takesMore = command.argumentHint != nil
      ranks[rank].append(
        Item(
          id: "runtime:\(name)", command: "/\(name)", matchedPrefix: rank == 0 ? token.count + 1 : 0,
          title: command.description, trailing: command.argumentHint,
          primary: takesMore ? "Add to message" : "Run /\(name)", isRuntime: true,
          note: takesMore
            ? "\(connection.label) runs it when you send the message"
            : "\(connection.label) runs it as a message",
          action: .runtime(command)))
    }
    return ranks.flatMap { $0 }
  }

  /// A command's key, where there are keys: the Mac. A phone's list does not name one.
  private static func shortcut(_ definition: CommandDefinition) -> String? {
    #if os(macOS)
      definition.shortcutLabel
    #else
      nil
    #endif
  }

  /// Completions are up: there is something to pick. A token nothing answers to shows nothing, and
  /// the draft is then an ordinary message.
  var isShowing: Bool { state != .closed && !items.isEmpty }

  var selected: Item? {
    let items = self.items
    return items.first { $0.id == selection } ?? items.first
  }

  /// The words under the list: where the commands apply, when a value takes effect, or a failure.
  var context: String {
    if let failure { return failure }
    if let reason = selected?.reason { return reason }
    if let note = selected?.note { return note }
    if case .choices(let id) = state { return workspace.effectNote(of: id, target: target) }
    switch target {
    case .thread(let id): return workspace.thread(id: id).map(ThreadSearch.shownTitle) ?? ""
    case .draft: return "New thread"
    default: return ""
    }
  }

  /// The heading over a command's values.
  var choiceTitle: String? {
    guard case .choices(let id) = state else { return nil }
    return CommandCatalog.plain(CommandCatalog.definition(id).title)
  }

  func select(_ id: String) {
    selection = id
    failure = nil
  }

  func move(by delta: Int) {
    let items = self.items
    guard !items.isEmpty else { return }
    let current = items.firstIndex { $0.id == selected?.id } ?? 0
    select(items[ThreadSearch.step(current, by: delta, count: items.count)].id)
  }

  /// Escape: from a command's values back to the commands (the slash returns to the draft), and
  /// from the commands to closed, leaving the typed token as text.
  func dismiss() -> TextChange {
    if case .choices = state {
      state = .commands
      token = ""
      selection = nil
      failure = nil
      return "/"
    }
    close()
    return nil
  }

  /// Return: pick the selected row. An app command with values lists them and any other runs. A
  /// runtime command is a message: one that takes nothing more is sent, one that does is completed
  /// in the draft for the rest to be typed.
  func choose() async -> Pick? {
    guard !running, let item = selected, item.isAvailable else { return nil }
    switch item.action {
    case .command(let id):
      if CommandCatalog.definition(id).argument == .choice {
        state = .choices(id)
        selection = nil
        failure = nil
        return .text("")
      }
      return await run(id, target: id == .newThread ? .workspace : target, argument: nil).map(Pick.text)
    case .choice(let value):
      guard case .choices(let id) = state else { return nil }
      return await run(id, target: target, argument: value).map(Pick.text)
    case .runtime(let command):
      close()
      return command.argumentHint == nil ? .send("/\(command.name)") : .text("/\(command.name) ")
    }
  }

  private func run(_ id: CommandID, target: CommandTarget, argument: String?) async -> TextChange {
    running = true
    let outcome = await workspace.run(id, target: target, argument: argument)
    running = false
    switch outcome {
    case .completed(let spoken):
      AccessibilityNotification.Announcement(spoken).post()
      let wasToken = state == .commands
      close()
      return wasToken ? "" : nil
    case .failed(let reason), .unknown(let reason):
      failure = reason
      return nil
    }
  }
}

/// The completions, drawn as one floating panel tied to the composer's edges.
struct SlashCompletions: View {
  let slash: SlashController
  /// Runs a pick and applies what it does to the draft's text.
  let choose: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let items = slash.items
    let selected = slash.selected?.id
    VStack(alignment: .leading, spacing: 0) {
      if let title = slash.choiceTitle {
        LLABadge(title, raised: true)
          .padding(.horizontal, LLA.Space.s).padding(.top, LLA.Space.xs).padding(.bottom, LLA.Space.s)
      }
      // A runtime can list a hundred commands: the rows scroll past `visibleRows`, following the
      // selection, and the panel never grows beyond that.
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
              Button {
                slash.select(item.id)
                choose()
              } label: {
                row(item, selected: item.id == selected)
              }
              .buttonStyle(.plain)
              .accessibilityLabel(
                [item.command, item.title, item.trailing, item.isCurrent ? "Current" : nil, item.reason]
                  .compactMap { $0 }.joined(separator: ", ")
              )
              .accessibilityAddTraits(item.id == selected ? [.isButton, .isSelected] : .isButton)
              .accessibilityIdentifier("slash-row")
              .id(item.id)
            }
          }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: CGFloat(min(items.count, Self.visibleRows)) * Self.rowHeight)
        .onChange(of: selected) { _, id in
          if let id { proxy.scrollTo(id) }
        }
      }
      Hairline().padding(.top, LLA.Space.s)
      HStack(spacing: LLA.Space.l) {
        Text(slash.context)
          .font(LLAFont.caption)
          .foregroundStyle(slash.failure == nil ? LLA.Color.muted : LLA.Color.danger)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
        if let primary = slash.selected?.primary {
          HStack(spacing: LLA.Space.s) {
            Text(primary).font(LLAFont.caption).foregroundStyle(LLA.Color.ink).lineLimit(1)
            #if os(macOS)
              Text("\u{21A9}").font(LLAFont.codeSmall).foregroundStyle(LLA.Color.muted)
            #endif
          }
          .opacity(slash.selected?.isAvailable == true ? 1 : 0.45)
        }
      }
      .padding(.horizontal, LLA.Space.s)
      .padding(.top, LLA.Space.s)
    }
    .padding(LLA.Space.s)
    .background(LLA.Color.bg, in: RoundedRectangle(cornerRadius: LLA.Radius.menu, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: LLA.Radius.menu, style: .continuous).strokeBorder(LLA.Color.rule)
    )
    .llaPopoverShadow()
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Commands")
    .accessibilityIdentifier("slash-completions")
  }

  static let visibleRows = 8
  static var rowHeight: CGFloat { max(LLA.Metrics.row, 32) }

  private func row(_ item: SlashController.Item, selected: Bool) -> some View {
    HStack(spacing: LLA.Space.s) {
      if let command = item.command {
        (Text(command.prefix(item.matchedPrefix)).font(LLAFont.mono(LLAFont.scale.code, weight: .semibold))
          + Text(command.dropFirst(item.matchedPrefix)).font(LLAFont.code))
          .foregroundStyle(item.isAvailable ? LLA.Color.ink : LLA.Color.muted)
          .lineLimit(1)
          .frame(minWidth: 104, alignment: .leading)
          .layoutPriority(1)
      }
      Text(item.title).font(LLAFont.row)
        .foregroundStyle(item.isAvailable && !item.isRuntime ? LLA.Color.ink : LLA.Color.muted)
        .lineLimit(1).truncationMode(.tail)
      Spacer(minLength: LLA.Space.s)
      if let trailing = item.trailing {
        Text(trailing).font(item.isRuntime ? LLAFont.codeSmall : LLAFont.caption)
          .foregroundStyle(LLA.Color.muted).lineLimit(1)
      }
      if item.isCurrent {
        Text("Current").llaCaption().fixedSize()
        Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
          .foregroundStyle(LLA.Color.ink).accessibilityHidden(true)
      }
    }
    .padding(.horizontal, LLA.Space.s)
    .frame(height: Self.rowHeight)
    .background(
      RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous)
        .fill(selected ? LLA.Color.surfaceRaised : .clear)
    )
    .contentShape(Rectangle())
  }
}

/// Where the completions sit relative to the field.
nonisolated enum SlashPlacement: Sendable { case above, below }

/// What a composer field asks its screen to present: its completions, tied to where the field is.
nonisolated struct SlashPresentation {
  var field: Anchor<CGRect>
  var slash: SlashController
  var placement: SlashPlacement
  var choose: @MainActor () -> Void
}

nonisolated enum SlashPresentationKey: PreferenceKey {
  static var defaultValue: SlashPresentation? { nil }
  static func reduce(value: inout SlashPresentation?, nextValue: () -> SlashPresentation?) {
    value = value ?? nextValue()
  }
}

/// The completions, placed over the screen that hosts them: 8 pt from the field's edge, exactly as
/// wide, and moving nothing in the layout.
private struct SlashCompletionsLayer: View {
  let shown: SlashPresentation?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { proxy in
      if let shown, shown.slash.isShowing {
        let field = proxy[shown.field]
        // Below the field when it was asked for and fits; a short window puts the list above instead
        // of cutting it.
        let rows = CGFloat(min(shown.slash.items.count, SlashCompletions.visibleRows))
        let needed = rows * SlashCompletions.rowHeight + 96
        let roomBelow = proxy.size.height - field.maxY - LLA.Space.s
        let above =
          shown.placement == .above || (roomBelow < needed && field.minY - LLA.Space.s > roomBelow)
        SlashCompletions(slash: shown.slash, choose: shown.choose)
          .frame(width: field.width)
          .transition(
            .opacity.combined(with: .scale(scale: 0.98, anchor: above ? .bottomLeading : .topLeading))
          )
          .padding(.leading, field.minX)
          .padding(.top, above ? 0 : field.maxY + LLA.Space.s)
          .frame(maxWidth: .infinity, alignment: .leading)
          .frame(height: above ? max(field.minY - LLA.Space.s, 0) : nil, alignment: .bottom)
      }
    }
    .animation(
      reduceMotion ? nil : .snappy(duration: 0.12, extraBounce: 0), value: shown?.slash.isShowing == true)
  }
}

extension View {
  /// Ask the screen to present `slash`'s completions beside this field. The screen presents them
  /// (`slashCompletionsHost`) rather than the field, because a field in a bottom bar cannot take
  /// touches outside the bar.
  func slashCompletions(
    _ slash: SlashController, placement: SlashPlacement, choose: @escaping @MainActor () -> Void
  ) -> some View {
    anchorPreference(key: SlashPresentationKey.self, value: .bounds) {
      SlashPresentation(field: $0, slash: slash, placement: placement, choose: choose)
    }
  }

  /// Present, over this screen, the completions a composer field inside it asks for.
  func slashCompletionsHost() -> some View {
    overlayPreferenceValue(SlashPresentationKey.self) { SlashCompletionsLayer(shown: $0) }
  }
}

extension SlashController {
  /// Arrow keys and Escape go to the completions while they show; otherwise they are the editor's.
  /// Escape here only ever closes the completions: it never reaches a running turn.
  /// Return picks the selected row through `choose` (the composer's own pick, which applies what it
  /// does to the draft): the editor has the key before the round control's shortcut does, and would
  /// add a line. Shift-Return is still a new line.
  func handle(_ press: KeyPress, text: Binding<String>, choose: () -> Void) -> KeyPress.Result {
    guard isShowing else { return .ignored }
    switch press.key {
    case .return:
      guard !press.modifiers.contains(.shift) else { return .ignored }
      choose()
    case .upArrow: move(by: -1)
    case .downArrow: move(by: 1)
    case .escape:
      if let change = dismiss() { text.wrappedValue = change }
    default: return .ignored
    }
    return .handled
  }
}
