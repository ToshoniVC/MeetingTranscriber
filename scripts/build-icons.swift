#!/usr/bin/env swift
// Render Branding/logo.svg into Jot/Assets.xcassets/AppIcon.appiconset at every
// macOS app-icon size, and rewrite the iconset's Contents.json to reference them.
//
// Run from the repo root:
//     swift scripts/build-icons.swift
//
// Uses NSImage's built-in SVG support (macOS 13+). No external deps.

import AppKit
import Foundation

let sizes: [(pt: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let repoRoot = scriptURL
    .deletingLastPathComponent()  // scripts/
    .deletingLastPathComponent()  // repo root
let svgURL = repoRoot.appendingPathComponent("Branding/logo.svg")
let iconset = repoRoot.appendingPathComponent("Jot/Assets.xcassets/AppIcon.appiconset")

guard FileManager.default.fileExists(atPath: svgURL.path) else {
    FileHandle.standardError.write(Data("SVG not found at \(svgURL.path)\n".utf8))
    exit(1)
}
guard FileManager.default.fileExists(atPath: iconset.path) else {
    FileHandle.standardError.write(Data("Iconset not found at \(iconset.path)\n".utf8))
    exit(1)
}
guard let image = NSImage(contentsOf: svgURL) else {
    FileHandle.standardError.write(Data("Failed to load SVG\n".utf8))
    exit(1)
}

func renderPNG(size px: Int, to url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "build-icons", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not allocate bitmap rep"])
    }
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(
        in: NSRect(x: 0, y: 0, width: px, height: px),
        from: .zero,
        operation: .copy,
        fraction: 1.0
    )
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "build-icons", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
    }
    try data.write(to: url)
}

var images: [[String: String]] = []
var rendered: Set<String> = []
for (pt, scale) in sizes {
    let px = pt * scale
    let name = "icon_\(pt)x\(pt)@\(scale)x.png"
    let out = iconset.appendingPathComponent(name)
    if !rendered.contains(name) {
        do {
            try renderPNG(size: px, to: out)
            print("rendered \(name) (\(px)x\(px))")
            rendered.insert(name)
        } catch {
            FileHandle.standardError.write(Data("failed \(name): \(error)\n".utf8))
            exit(1)
        }
    }
    images.append([
        "idiom": "mac",
        "scale": "\(scale)x",
        "size": "\(pt)x\(pt)",
        "filename": name,
    ])
}

let contents: [String: Any] = [
    "images": images,
    "info": ["author": "xcode", "version": 1],
]
let data = try JSONSerialization.data(
    withJSONObject: contents,
    options: [.prettyPrinted, .sortedKeys]
)
try data.write(to: iconset.appendingPathComponent("Contents.json"))
print("updated Contents.json")
