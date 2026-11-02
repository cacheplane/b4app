#!/usr/bin/env swift
// Rasterises the b4.run dark icon (the vendored SVG: a white "b4" on #17181B) into the shared AppIcon
// set for both app targets. Run from the repository root:
//   swift Scripts/make-app-icon.swift
// macOS sizes draw the icon as the standard rounded-square tile with a 10% margin around it; the SVG
// is a plain square, so the tile's corners are clipped here. The iOS 1024 fills the square edge to
// edge, opaque, because iOS masks its own corners and rejects alpha. The dark kit has no separate
// small variant, but it ships hand-tuned 16 and 32 px PNGs (Scripts/app-icon-sources/, vendored
// unchanged from the b4run repository); the 16 and 32 px Mac renders use those, filling the tile with
// no margin because a 10% margin leaves the mark muddy at that size. Every other size is drawn from
// the SVG.
import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let brand = root.appendingPathComponent("Sources/WorkspaceUI/Resources/Brand")
let out = root.appendingPathComponent("Apps/Shared/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let kitPNGs = root.appendingPathComponent("Scripts/app-icon-sources")

guard let icon = NSImage(contentsOf: brand.appendingPathComponent("b4-icon-dark.svg")) else {
  FileHandle.standardError.write(Data("cannot load the brand SVG\n".utf8))
  exit(1)
}

func render(_ source: NSImage, pixels: Int, inset: CGFloat, cornerRadius: CGFloat) -> Data {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = NSSize(width: pixels, height: pixels)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSGraphicsContext.current?.imageInterpolation = .high
  let margin = CGFloat(pixels) * inset
  let side = CGFloat(pixels) - 2 * margin
  let tile = NSRect(x: margin, y: margin, width: side, height: side)
  if cornerRadius > 0 {
    let radius = side * cornerRadius
    NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius).addClip()
  }
  source.draw(in: tile, from: .zero, operation: .sourceOver, fraction: 1)
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
  var source = icon
  var inset: CGFloat = 0.1
  if pixels == 16 || pixels == 32 {
    guard let kit = NSImage(contentsOf: kitPNGs.appendingPathComponent("icon-dark-\(pixels).png")) else {
      FileHandle.standardError.write(Data("cannot load the kit PNG for \(pixels) px\n".utf8))
      exit(1)
    }
    source = kit
    inset = 0
  }
  try render(source, pixels: pixels, inset: inset, cornerRadius: 0.2237).write(to: out.appendingPathComponent(name))
  entries.append(Entry(filename: name, idiom: "mac", size: "\(points)x\(points)", scale: "\(scale)x", platform: nil))
}
try render(icon, pixels: 1024, inset: 0, cornerRadius: 0).write(to: out.appendingPathComponent("ios-1024.png"))
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
