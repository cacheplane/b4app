import SwiftUI
import UIKit
import WorkspaceMirror
import WorkspaceUI
import XCTest

@testable import WorkspaceLayoutHarness

/// Actual banner rendering, isolated from navigation. Root placement and interaction stay in UI tests.
@MainActor final class SyncBannerComponentTests: XCTestCase {
  func testHealthyBannerHasNoHeight() {
    let host = UIHostingController(rootView: SyncBanner(status: MirrorSyncStatus()))
    host.safeAreaRegions = []
    XCTAssertLessThan(host.sizeThatFits(in: CGSize(width: 390, height: 1000)).height, 1)
  }

  func testFailureRendersTextAndLeadingMarker() throws {
    let result = try render(width: 390, size: .large, lastSyncAt: nil)
    XCTAssertGreaterThan(result.inkCount, 100, "The actual text must render, not just a background.")
    XCTAssertEqual(try XCTUnwrap(result.markerMinX), 16, accuracy: 1)
    XCTAssertGreaterThan(result.height, 25)
    XCTAssertLessThan(result.height, 60)
  }

  func testMaximumTextWrapsOlderTimestamp() throws {
    let normal = try render(width: 320, size: .large, lastSyncAt: "2001-01-01T10:30:00Z")
    let large = try render(width: 320, size: .accessibility5, lastSyncAt: "2001-01-01T10:30:00Z")
    XCTAssertGreaterThan(large.height, normal.height * 2)
    XCTAssertGreaterThan(large.inkHeight, normal.inkHeight * 2)
    XCTAssertGreaterThan(large.inkCount, normal.inkCount)
    XCTAssertEqual(try XCTUnwrap(large.markerMinX), 16, accuracy: 1)
  }

  private struct Pixels {
    let height: CGFloat
    let inkCount: Int
    let inkHeight: Int
    let markerMinX: CGFloat?
  }

  private func render(width: CGFloat, size: DynamicTypeSize, lastSyncAt: String?) throws -> Pixels {
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene)
    let view = SyncBanner(status: MirrorSyncStatus(lastError: "offline", lastSyncAt: lastSyncAt))
      .environment(\.dynamicTypeSize, size)
      .environment(\.colorScheme, .light)
    let host = UIHostingController(rootView: view)
    host.safeAreaRegions = []
    window.rootViewController = host
    window.overrideUserInterfaceStyle = .light
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previousKeyWindow?.makeKey()
    }
    let fitting = host.sizeThatFits(in: CGSize(width: width, height: 2000))
    let bounds = CGRect(x: 0, y: 0, width: width, height: ceil(fitting.height))
    window.frame = bounds
    host.view.frame = bounds
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    var rendered = false
    let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
      rendered = host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
    }
    XCTAssertTrue(rendered, "UIKit must finish rendering the actual hosted view.")
    let attachment = XCTAttachment(image: image)
    attachment.name = "sync-banner-\(width)-\(size)"
    attachment.lifetime = .keepAlways
    add(attachment)
    let cgImage = try XCTUnwrap(image.cgImage)
    let width = cgImage.width
    let height = cgImage.height
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    try rgba.withUnsafeMutableBytes { bytes in
      let context = try XCTUnwrap(
        CGContext(
          data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    var inkCount = 0
    var inkRows = Set<Int>()
    var markerMinX: Int?
    for y in 0..<height {
      for x in 0..<width {
        let offset = (y * width + x) * 4
        let r = Int(rgba[offset])
        let g = Int(rgba[offset + 1])
        let b = Int(rgba[offset + 2])
        if max(r, g, b) < 100 {
          inkCount += 1
          inkRows.insert(y)
        }
        if r > 100 && r > g * 2 && r > b * 2 {
          markerMinX = min(markerMinX ?? x, x)
        }
      }
    }
    return Pixels(
      height: fitting.height, inkCount: inkCount,
      inkHeight: (inkRows.max() ?? 0) - (inkRows.min() ?? 0),
      markerMinX: markerMinX.map { CGFloat($0) })
  }
}
