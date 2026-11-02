import Foundation
import SwiftUI
import WidgetKit
import WorkspaceMirror
import WorkspaceProtocol
import WorkspaceUI

/// The top three threads, most urgent first (D-126), read from the mirror the app keeps in the App
/// Group. Small is one tap target that opens the first thread; medium makes each row a link.
struct AttentionWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "AttentionWidget", provider: GlanceProvider()) { entry in
      AttentionWidgetView(entry: entry)
    }
    .configurationDisplayName("Threads")
    .description("The threads that need you, most urgent first.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

/// The App Group and URL scheme from this extension's Info.plist (D-125); the app keeps its own copy.
nonisolated enum AppInfo {
  static var appGroup: String? {
    let value = (Bundle.main.object(forInfoDictionaryKey: "B4AppAppGroup") as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value : nil
  }

  static var urlScheme: String {
    let value =
      (Bundle.main.object(forInfoDictionaryKey: "B4AppURLScheme") as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.wholeMatch(of: /[A-Za-z][A-Za-z0-9+.\-]*/) != nil ? value : "b4app"
  }
}

nonisolated struct GlanceEntry: TimelineEntry {
  let date: Date
  let glance: Glance
}

/// Builds the timeline from the mirror: an entry now and one when the data turns stale, then a reload
/// fifteen minutes on. The app reloads it sooner after every batch that touched threads or projects.
nonisolated struct GlanceProvider: TimelineProvider {
  func placeholder(in context: Context) -> GlanceEntry {
    GlanceEntry(date: .now, glance: Self.sample)
  }

  /// Real data when the phone is linked; the gallery shows the sample before it is.
  func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
    let glance = Self.load()
    completion(GlanceEntry(date: .now, glance: context.isPreview && !glance.linked ? Self.sample : glance))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
    let now = Date.now
    let glance = Self.load()
    let entries = glance.entryDates(now: now).map { GlanceEntry(date: $0, glance: glance) }
    completion(Timeline(entries: entries, policy: .after(glance.reloadDate(now: now))))
  }

  /// `<group container>/b4app/mirror.sqlite`, or the unlinked glance when the group is unavailable.
  static func load() -> Glance {
    let location = MirrorLocation.storeDirectory(
      appGroup: AppInfo.appGroup, fallback: URL(fileURLWithPath: "/"))
    guard location.inGroup else { return Glance(linked: false, rows: [], asOf: nil) }
    return MirrorGlance.load(path: location.directory.appendingPathComponent(MirrorLocation.fileName).path)
  }

  static let sample = Glance(
    linked: true,
    rows: [
      GlanceRow(
        threadId: "sample-1", title: "Approve the schema migration", projectName: "b4app", band: .needsInput,
        pinned: false),
      GlanceRow(
        threadId: "sample-2", title: "Refactor the sync loop", projectName: "b4app", band: .working,
        pinned: false),
      GlanceRow(
        threadId: "sample-3", title: "Release notes for 0.2", projectName: nil, band: .unread, pinned: false),
    ],
    asOf: nil)
}

struct AttentionWidgetView: View {
  let entry: GlanceEntry
  @Environment(\.widgetFamily) private var family

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .containerBackground(LLA.Color.bg, for: .widget)
      .widgetURL(family == .systemSmall ? entry.glance.rows.first.map(Self.link) : nil)
  }

  @ViewBuilder private var content: some View {
    if !entry.glance.linked {
      message("Open Agent Workspace to see your threads.")
    } else if entry.glance.rows.isEmpty {
      message("No threads yet")
    } else {
      VStack(alignment: .leading, spacing: LLA.Space.s) {
        ForEach(entry.glance.rows, id: \.threadId) { row in
          if family == .systemSmall {
            GlanceRowView(row: row)
          } else {
            Link(destination: Self.link(row)) { GlanceRowView(row: row) }
          }
        }
        Spacer(minLength: 0)
        if let stale = entry.glance.staleLabel(at: entry.date) {
          Text(stale)
            .font(LLAFont.caption)
            .foregroundStyle(LLA.Color.muted)
            .lineLimit(1)
        }
      }
    }
  }

  private func message(_ text: String) -> some View {
    Text(text)
      .font(LLAFont.small)
      .foregroundStyle(LLA.Color.muted)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }

  private static func link(_ row: GlanceRow) -> URL {
    ThreadLink.url(threadId: row.threadId, scheme: AppInfo.urlScheme)
  }
}

/// One thread: its attention dot beside a one-line title, and under the title its project, muted, when
/// it has one.
struct GlanceRowView: View {
  let row: GlanceRow
  /// The dot's width (`AttentionDot` scales the same way), so the project lines up under the title.
  @ScaledMetric(relativeTo: .body) private var dot: CGFloat = 8

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: LLA.Space.s) {
        AttentionDot(band: row.band)
        Text(row.title.isEmpty ? "Untitled" : row.title)
          .font(LLAFont.smallStrong)
          .foregroundStyle(LLA.Color.ink)
          .lineLimit(1)
      }
      if let project = row.projectName {
        Text(project)
          .font(LLAFont.caption)
          .foregroundStyle(LLA.Color.muted)
          .lineLimit(1)
          .padding(.leading, dot + LLA.Space.s)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}
