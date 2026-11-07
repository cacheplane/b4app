import AppKit
import SwiftUI
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

/// A flexible transcript and expanded diagnostics compete for height in the installed thread pane.
/// Measuring the notice in isolation did not catch its primary text being compressed to one line.
@Suite(.serialized) @MainActor struct RecoveryCompressionTests {
  private let message =
    "This session is archived. Run `runtime unarchive 01900000-0000-7000-8000-000000000001` in Terminal, then choose Check again. Your transcript and draft are preserved."

  @Test(arguments: [
    CGSize(width: 340, height: 340), CGSize(width: 340, height: 400),
    CGSize(width: 672, height: 260), CGSize(width: 672, height: 400),
  ])
  func expandedDetailsPreservesTheWholeRecoveryMessage(_ size: CGSize) async throws {
    // Narrow text needs four lines plus controls; 260 points cannot hold that and a composer.
    let width = size.width
    let height = size.height
    let failure = WorkspaceError(.protocolInvalid, message, details: ["nativeMessage": "archived"])
    let notice = ThreadErrorNotice(
      error: message, failure: failure,
      remedy: Remediation(message: message, action: .checkAgain, actionTitle: "Check again"),
      perform: { _ in }, dismiss: {}, detailsExpanded: true)
    let reference = SnapshotWindow(
      rootView: Text(message).font(LLAFont.small).foregroundStyle(LLA.Color.danger)
        .frame(width: width - 2 * LLA.Space.m, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true).ignoresSafeArea(),
      size: CGSize(width: width, height: 400))
    defer { reference.close() }
    let window = SnapshotWindow(
      rootView: VStack(spacing: 0) {
        ScrollView { Text(String(repeating: "Cached transcript. ", count: 300)) }
        // Use the shipped controls container and match the composer's padded vertical stack.
        ThreadControls(prioritizingRecovery: true) {
          VStack(alignment: .leading, spacing: LLA.Space.s) {
            notice
            TextField("Message", text: .constant("Preserved draft"))
              .textFieldStyle(.plain)
              .padding(.horizontal, LLA.Space.m)
              .frame(height: 48)
              .background(LLA.Color.surface, in: RoundedRectangle(cornerRadius: LLA.Radius.card))
          }
          .padding(.top, LLA.Space.s)
          .padding(.bottom, LLA.Space.l)
        }
      }
      .frame(width: width, height: height).background(LLA.Color.bg).ignoresSafeArea(),
      size: CGSize(width: width, height: height))
    defer { window.close() }
    // SwiftUI/AppKit draw on later run-loop passes, as in SnapshotWindow.capture.
    for _ in 0..<4 {
      pump()
      try await Task.sleep(for: .milliseconds(50))
    }
    window.host.layoutSubtreeIfNeeded()
    reference.host.layoutSubtreeIfNeeded()
    let actual = try #require(recoveryInkHeight(in: window.host))
    let full = try #require(recoveryInkHeight(in: reference.host))
    #expect(full > 20, "the reference must require multiple lines")
    #expect(actual >= full - 1, "recovery text was compressed: \(actual) vs \(full) points")
    if let directory = ProcessInfo.processInfo.environment["B4APP_SNAPSHOT_DIR"] {
      try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
      try await window.capture(to: "\(directory)/compressed-\(Int(width))-\(Int(height)).png")
    }
  }

  private func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

  /// Only the primary recovery text uses danger ink. Its rendered line extent catches truncation
  /// that the full accessibility value and overall notice size both conceal.
  private func recoveryInkHeight(in host: NSView) -> CGFloat? {
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let image = bitmap.cgImage else { return nil }
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    return pixels.withUnsafeMutableBytes { buffer in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
      else { return nil }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      let bytes = buffer.bindMemory(to: UInt8.self)
      var first = height
      var last = -1
      for y in 0..<height {
        for x in 0..<width {
          let i = (y * width + x) * 4
          let red = Int(bytes[i])
          if red > 80, red > Int(bytes[i + 1]) + 40, red > Int(bytes[i + 2]) + 30 {
            first = min(first, y)
            last = max(last, y)
          }
        }
      }
      guard last >= first else { return nil }
      return CGFloat(last - first + 1) * host.bounds.height / CGFloat(height)
    }
  }
}
