import SwiftUI
import WorkspaceProtocol

/// The line under a connection's name: the plan and account, the try while checking, or the reason in
/// a few words when it needs you. Pure, so the copy is pinned by tests.
enum ConnectionSummary {
  static func subtitle(_ connection: Connection, reading: UsageReading?, check: ConnectionCheck?) -> String {
    if let check {
      return check.attempt > 1 ? "Checking… try \(check.attempt) of \(check.attempts)" : "Checking…"
    }
    if let reason = reason(connection, blocked: reading?.blocked ?? false) { return reason }
    if connection.kind == .b4 { return host(connection.target) ?? connection.target }
    let plan = reading?.planType.flatMap(planName)
    guard let account = connection.nativeScope, !account.isEmpty else { return plan ?? "Not signed in" }
    return [plan, account].compactMap { $0 }.joined(separator: " · ")
  }

  /// Why the status icon says "needs you", or nil when it does not.
  static func reason(_ connection: Connection, blocked: Bool) -> String? {
    switch connection.status {
    case .offline:
      return connection.kind == .b4 ? "Can't reach \(host(connection.target) ?? "the server")" : "Not running"
    case .incompatible:
      return connection.kind == .b4 ? "Not an agent route" : "Update needed"
    case .error:
      return "Unavailable"
    default:
      break
    }
    if [.required, .error].contains(connection.authStatus) { return "Sign-in needed" }
    if blocked { return "Usage limit reached" }
    return nil
  }

  /// "localhost:3000" from "http://localhost:3000".
  static func host(_ target: String) -> String? {
    guard let url = URL(string: target), let host = url.host() else { return nil }
    return url.port.map { "\(host):\($0)" } ?? host
  }

  /// The plan as people say it: "promax" → "Pro Max". Codes without a common name are title-cased;
  /// "unknown" is no name at all.
  static func planName(_ raw: String) -> String? {
    let known = [
      "free": "Free", "go": "Go", "plus": "Plus", "pro": "Pro", "prolite": "Pro Lite", "promax": "Pro Max",
      "team": "Team", "business": "Business", "enterprise": "Enterprise", "edu": "Edu",
    ]
    if raw == "unknown" || raw.isEmpty { return nil }
    if let name = known[raw] { return name }
    return raw.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
  }

  /// The windows a reading has, in order (5-hour, then weekly), so a plan with one window shows it
  /// at the leading edge.
  static func windows(_ reading: UsageReading) -> [(title: String, window: UsageWindow)] {
    [("5-hour", reading.fiveHour), ("Weekly", reading.weekly)].compactMap { title, window in
      window.map { (title, $0) }
    }
  }
}

/// One connection (settings connections design, card option B): the mark, name, and one line of
/// detail, the status icon, a "…" menu on the Mac, and the plan's windows (Codex, Claude) or the tokens
/// used (B4) beneath.
struct ConnectionCardView: View {
  @Bindable var model: WorkspaceModel
  let connection: Connection
  let edit: () -> Void
  @Environment(\.dynamicTypeSize) private var typeSize
  @ScaledMetric(relativeTo: .body) private var markSlot: CGFloat = 24

  private var usage: ConnectionUsage? { model.usage[connection.id] }
  private var check: ConnectionCheck? { model.checks[connection.id] }

  var body: some View {
    let status = LLAStatus(
      connection: connection, checking: check != nil, blocked: usage?.reading?.blocked ?? false)
    LLACard(fill: .surface) {
      VStack(alignment: .leading, spacing: LLA.Space.m) {
        header(status)
        TimelineView(.periodic(from: .now, by: 30)) { context in
          details(now: context.date)
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("connection-\(connection.id)")
  }

  private func header(_ status: LLAStatus) -> some View {
    let subtitle = ConnectionSummary.subtitle(connection, reading: usage?.reading, check: check)
    return HStack(spacing: LLA.Space.s) {
      RuntimeMark(kind: connection.kind, height: 16).frame(width: markSlot, height: markSlot)
      VStack(alignment: .leading, spacing: 2) {
        Text(connection.label).font(LLAFont.bodyStrong).foregroundStyle(LLA.Color.ink)
          .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
        Text(subtitle)
          .font(connection.kind == .b4 && status == .ok ? LLAFont.codeSmall : LLAFont.small)
          .foregroundStyle(LLA.Color.muted)
          .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
          .truncationMode(.middle)
      }
      Spacer(minLength: LLA.Space.s)
      LLAStatusIcon(
        status: status,
        detail: ConnectionSummary.reason(connection, blocked: usage?.reading?.blocked ?? false))
      if WorkspaceDevice.managesWorkspace { menu }
    }
  }

  private var menu: some View {
    Menu {
      Button("Check") { Task { await model.checkConnection(id: connection.id) } }
      Button("Edit…", action: edit)
      if connection.kind != .b4, connection.authStatus != .authenticated {
        Button(connection.kind == .codex ? "Sign in with ChatGPT…" : "Sign in to Claude…") {
          Task { await model.login(connectionId: connection.id) }
        }
      }
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(LLA.Color.muted)
        .frame(width: LLA.Metrics.control, height: LLA.Metrics.control)
        .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel("Connection actions")
    .disabled(model.busy && check == nil)
  }

  @ViewBuilder private func details(now: Date) -> some View {
    if !WorkspaceDevice.managesWorkspace {
      note("Usage shows on your Mac")
    } else if connection.kind == .b4 {
      if let tokens = usage?.tokens {
        HStack(alignment: .top, spacing: LLA.Space.l) {
          figure("Today", tokens.today)
          figure("This week", tokens.week)
        }
      }
    } else if let reading = usage?.reading, reading.fiveHour != nil || reading.weekly != nil {
      VStack(alignment: .leading, spacing: LLA.Space.s) {
        meters(reading, now: now)
        if connection.kind == .claude {
          note("\(UsageFormat.age(reading.observedAt, now: now)), from the last turn")
        }
      }
    } else {
      note(connection.kind == .claude ? "Usage appears after the first turn" : "Usage unavailable")
    }
  }

  @ViewBuilder private func meters(_ reading: UsageReading, now: Date) -> some View {
    let layout =
      typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: LLA.Space.m))
      : AnyLayout(HStackLayout(alignment: .top, spacing: LLA.Space.l))
    let windows = ConnectionSummary.windows(reading)
    layout {
      Group {
        ForEach(windows, id: \.title) { UsageMeter(title: $0.title, window: $0.window, now: now) }
        // One window keeps the two-column grid, so its bar is as long as on a card with two.
        if windows.count == 1, !typeSize.isAccessibilitySize { Color.clear.frame(height: 0) }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func figure(_ title: String, _ count: Int) -> some View {
    VStack(alignment: .leading, spacing: LLA.Space.xs) {
      Text(title).font(LLAFont.caption).foregroundStyle(LLA.Color.muted)
      HStack(alignment: .firstTextBaseline, spacing: LLA.Space.xs) {
        Text(UsageFormat.tokens(count)).font(LLAFont.title).monospacedDigit().foregroundStyle(LLA.Color.ink)
        Text("tokens").font(LLAFont.caption).foregroundStyle(LLA.Color.muted)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private func note(_ text: String) -> some View {
    Text(text).font(LLAFont.caption).foregroundStyle(LLA.Color.muted)
  }
}
