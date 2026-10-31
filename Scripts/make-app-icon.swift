#!/usr/bin/env swift
// Rasterises the LiveLoveApp icon (the vendored outlined SVG) into the shared AppIcon set for both
// app targets. Run from the repository root:
//   swift Scripts/make-app-icon.swift
// macOS sizes leave the standard 10% margin around the tile; the iOS 1024 fills the square on ink
// because iOS masks its own corners and rejects alpha. Below 24 px the brand's small icon is used.
import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let brand = root.appendingPathComponent("Sources/WorkspaceUI/Resources/Brand")
let out = root.appendingPathComponent("Apps/Shared/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

guard let icon = NSImage(contentsOf: brand.appendingPathComponent("lla-icon.svg")),
  let small = NSImage(contentsOf: brand.appendingPathComponent("lla-icon-small.svg"))
else {
  FileHandle.standardError.write(Data("cannot load the brand SVGs\n".utf8))
  exit(1)
}

func render(_ source: NSImage, pixels: Int, inset: CGFloat, background: NSColor?) -> Data {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = NSSize(width: pixels, height: pixels)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSGraphicsContext.current?.imageInterpolation = .high
  if let background {
    background.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: pixels, height: pixels)).fill()
  }
  let margin = CGFloat(pixels) * inset
  let side = CGFloat(pixels) - 2 * margin
  source.draw(
    in: NSRect(x: margin, y: margin, width: side, height: side), from: .zero, operation: .sourceOver,
    fraction: 1)
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

struct Entry {
  var filename: String
  var idiom: String
  var size: String
  var scale: String?
  var platform: String?
}

var entries: [Entry] = []
// (point size, scale) pairs required for a macOS app icon.
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
  let pixels = points * scale
  let name = "mac-\(points)x\(points)@\(scale)x.png"
  let source = pixels < 24 ? small : icon
  try render(source, pixels: pixels, inset: 0.1, background: nil).write(to: out.appendingPathComponent(name))
  entries.append(Entry(filename: name, idiom: "mac", size: "\(points)x\(points)", scale: "\(scale)x", platform: nil))
}
let ink = NSColor(srgbRed: 13 / 255, green: 13 / 255, blue: 13 / 255, alpha: 1)
try render(icon, pixels: 1024, inset: 0, background: ink).write(to: out.appendingPathComponent("ios-1024.png"))
entries.append(Entry(filename: "ios-1024.png", idiom: "universal", size: "1024x1024", scale: nil, platform: "ios"))

var images: [[String: String]] = []
for entry in entries {
  var image = ["filename": entry.filename, "idiom": entry.idiom, "size": entry.size]
  if let scale = entry.scale { image["scale"] = scale }
  if let platform = entry.platform { image["platform"] = platform }
  images.append(image)
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: out.appendingPathComponent("Contents.json"))
print("wrote \(entries.count) images to \(out.path)")
