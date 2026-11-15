// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT
//
// Generates the app icon: the mark in white on a rounded-rect tile with a dark
// purple gradient, following the macOS icon grid (content rect inset 10% per
// side).
//
// The mark comes from Sources/llmenubar/LogoArtwork.swift through LogoMark.swift,
// which `make icon` compiles together with this file, so the icon and the app's
// menu-bar glyph share one set of coordinates.
//
// Usage: make icon      (run from the repository root; writes Resources/AppIcon.icns)
// Requires: /usr/bin/iconutil (ships with macOS).
//
// The optional first argument is the output path.

import AppKit

/// Render one square icon PNG at the given pixel size.
func renderPNG(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let size = CGFloat(pixels)
    let inset = size * 0.10
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = rect.width * 0.225

    // Dark at the bottom (#200D3C) to lighter at the top (#3F2F57).
    NSGradient(
        starting: NSColor(calibratedRed: 0.125, green: 0.051, blue: 0.235, alpha: 1),
        ending: NSColor(calibratedRed: 0.247, green: 0.184, blue: 0.341, alpha: 1))!
        .draw(in: NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius), angle: 90)

    // The mark's own bounds, not a line box, are centered on the tile.
    let side = rect.width * LogoArtwork.iconHeightFraction
    let markRect = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
    let context = NSGraphicsContext.current!.cgContext
    context.addPath(LogoMark.path(fitting: markRect))
    context.setFillColor(NSColor.white.cgColor)
    context.fillPath()

    return rep.representation(using: .png, properties: [:])!
}

// Standard 10-image iconset (16 → 1024, with @2x variants).
let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let fm = FileManager.default
let repoRoot = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconsetURL = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
let outputURL = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : repoRoot.appendingPathComponent("Resources/AppIcon.icns")

try? fm.removeItem(at: iconsetURL)
try fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

for (name, pixels) in sizes {
    try renderPNG(pixels: pixels).write(to: iconsetURL.appendingPathComponent("\(name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
try? fm.removeItem(at: iconsetURL)

guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed (exit \(iconutil.terminationStatus))\n".utf8))
    exit(1)
}
print("wrote \(outputURL.path)")
