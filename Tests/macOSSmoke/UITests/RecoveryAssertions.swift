import AppKit
import XCTest

extension RecoverySmokeTests {
  @MainActor func checkRenderedMessage(_ app: XCUIApplication, root: URL) throws {
    let message = app.staticTexts["recovery-message"]
    let actualShot = message.screenshot()
    let actual = try XCTUnwrap(dangerInkHeight(actualShot.image, points: message.frame.height))
    let attachment = XCTAttachment(screenshot: actualShot)
    attachment.name = "actual-recovery-message"
    attachment.lifetime = .keepAlways
    add(attachment)
    try JSONEncoder().encode(["width": message.frame.width])
      .write(to: root.appendingPathComponent("reference.json"), options: .atomic)
    app.typeKey("r", modifierFlags: [.command, .option])
    let reference = app.staticTexts["fixture.reference"]
    try requireElement(reference, in: app, timeout: 5)
    let referenceShot = reference.screenshot()
    let expected = try XCTUnwrap(dangerInkHeight(referenceShot.image, points: reference.frame.height))
    let referenceAttachment = XCTAttachment(screenshot: referenceShot)
    referenceAttachment.name = "unconstrained-recovery-reference"
    referenceAttachment.lifetime = .keepAlways
    add(referenceAttachment)
    XCTAssertGreaterThan(expected, 20, "Reference must require multiple rendered lines")
    XCTAssertGreaterThanOrEqual(
      actual, expected - 1, "Recovery message is visibly truncated: \(actual) vs \(expected) points")
    app.windows["Recovery reference"].buttons[XCUIIdentifierCloseWindow].click()
  }

  /// Same-machine reference avoids a platform-specific golden image; normalize pixels to points.
  private func dangerInkHeight(_ image: NSImage, points: CGFloat) -> CGFloat? {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let width = cg.width
    let height = cg.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    return pixels.withUnsafeMutableBytes { buffer in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
      else { return nil }
      context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
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
      return last >= first ? CGFloat(last - first + 1) * points / CGFloat(height) : nil
    }
  }
}
