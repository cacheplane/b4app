import AppKit
import Foundation
import SwiftUI
import Testing
import WorkspaceMirror
import WorkspaceProtocol
import WorkspaceSync

@testable import WorkspaceUI

/// A thread whose turn waits on a pending Claude `tool_permission` request, as the coordinator
/// stored it on 2026-10-31 when the window went blank. Read in place like the sync fixture.
private nonisolated func waitingThread(file: StaticString = #filePath) throws -> [StoredChange] {
  let url = URL(fileURLWithPath: "\(file)")
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/ui/waiting-thread.json")
  return try JSONCoding.decoder.decode([StoredChange].self, from: Data(contentsOf: url))
}

private nonisolated func edited(
  _ change: StoredChange, id: String? = nil, _ edit: (inout [String: JSONValue]) -> Void
)
  -> StoredChange
{
  var value = change.value?.objectValue ?? [:]
  if let id { value["id"] = .string(id) }
  edit(&value)
  return StoredChange(
    hubSeq: change.hubSeq, deviceId: change.deviceId, deviceSeq: change.deviceSeq, wall: change.wall,
    table: change.table, rowId: id ?? change.rowId, op: change.op, column: change.column,
    value: .object(value))
}

/// The thread detail must fit the smallest window whatever a runtime sends. On macOS 26 the
/// `NavigationSplitView` measures its detail column's minimum size, and when that exceeded the
/// window (a wrapped `fixedSize(vertical:)` command outside any scroll view measured 4,749 points at
/// zero width) the split view drew nothing in either column; near the limit the composer was pushed
/// off the bottom instead. Measured with `NSHostingController.sizeThatFits(in:)`, which is what the
/// split view asks, so this needs no on-screen window (D-047).
@Suite(.serialized) @MainActor struct DetailMinimumSizeTests {
  /// The title bar and toolbar above the split view in the app window.
  private static let titleBar: CGFloat = 52
  /// The detail column at the sidebar's ideal width.
  private static let detailWidth = LLA.Metrics.minimumWindow.width - 290
  private static let availableHeight = LLA.Metrics.minimumWindow.height - titleBar

  struct Variant: CustomStringConvertible {
    var name: String
    var rows: [StoredChange]
    var description: String { name }
  }

  private nonisolated static func variants() throws -> [Variant] {
    let stored = try waitingThread()
    let request = try #require(stored.first { $0.table == "runtimeRequests" })
    let thread = try #require(stored.first { $0.table == "threads" })
    let others = stored.filter { $0.table != "runtimeRequests" }
    let longText = String(repeating: "git log --oneline --graph --decorate --all ", count: 80)
    let longRequest = edited(request) {
      var payload = $0["payload"]?.objectValue ?? [:]
      var details = payload["request"]?.objectValue ?? [:]
      details["command"] = .string(longText)
      details["reason"] = .string(longText)
      payload["request"] = .object(details)
      $0["payload"] = .object(payload)
    }
    let secondRequest = edited(longRequest, id: "request-2") { $0["nativeRequestId"] = .string("native-2") }
    let brokenThread = edited(thread) {
      $0["continuity"] = .string(ThreadContinuity.identityChanged.rawValue)
    }
    return [
      Variant(name: "as stored", rows: stored),
      Variant(name: "long command and reason", rows: others + [longRequest]),
      Variant(name: "two long requests", rows: others + [longRequest, secondRequest]),
      Variant(
        name: "continuity banner and a long request",
        rows: others.map { $0.table == "threads" ? brokenThread : $0 } + [longRequest]),
    ]
  }

  @Test(arguments: try variants())
  func threadDetailFitsTheMinimumWindow(_ variant: Variant) async throws {
    let store = try MirrorStore.inMemory()
    let transport = MirrorTransport(store: store, version: "0.2.0")
    let model = WorkspaceModel(transportProvider: { transport })
    model.connect()
    let link = await model.settledLink()
    try #require(link == .ready, "the model did not connect: \(model.linkMessage ?? "no message")")
    transport.publish(try store.apply(variant.rows))
    try await waitUntil("thread listed") { model.threads.count == 1 }
    let threadId = try #require(model.threads.first?.id)
    await model.openThread(id: threadId)
    let expectedRequests = variant.rows.filter { $0.table == "runtimeRequests" }.count
    try await waitUntil("detail") { model.detail?.requests.count == expectedRequests }
    // A long draft: the composer's hidden measuring copy of the text must stay clamped too.
    model.composerText = String(repeating: "a draft that goes on and on ", count: 200)

    let controller = NSHostingController(rootView: ThreadsView(model: model))
    let atZero = controller.sizeThatFits(in: .zero)
    let atDetailWidth = controller.sizeThatFits(in: CGSize(width: Self.detailWidth, height: 0))
    #expect(
      atZero.height <= Self.availableHeight,
      "\(variant): minimum height \(atZero.height) at zero width exceeds the window's \(Self.availableHeight)"
    )
    #expect(
      atDetailWidth.height <= Self.availableHeight,
      "\(variant): minimum height \(atDetailWidth.height) at \(Self.detailWidth) wide exceeds \(Self.availableHeight)"
    )
    await model.disconnect()
  }
}
