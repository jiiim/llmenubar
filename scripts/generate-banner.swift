// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT
//
// Generates the README banners: the app icon beside the name and the
// repository, 1280 by 640 with a transparent background, once with black text
// for a light page and once with white text for a dark one. The README picks
// between them with a <picture> element.
//
// The mark comes from Sources/llmenubar/LogoArtwork.swift through
// LogoMark.swift, so builds from this repository draw the placeholder and the
// maintainer's brand repository draws the logo with the same generator.
//
// Run by the maintainer's brand repository, whose `make banner` compiles this
// file with its own LogoArtwork.swift; the banners with the logo are published
// from a separate all-rights-reserved repository. Compile it with
// Sources/llmenubar/LogoMark.swift and Sources/llmenubar/LogoArtwork.swift to
// get the placeholder version.
//
// The optional first argument is the output folder (default docs/images).

import AppKit

let canvas = NSSize(width: 1280, height: 640)
let tile = NSRect(x: 127, y: (canvas.height - 410) / 2, width: 410, height: 410)
let textLeft: CGFloat = 583
let textMaxWidth: CGFloat = canvas.width - textLeft - 56

let title = "LLMenuBar"
let owner = "jiiim/"
let repository = "llmenubar"

/// A line of text fitted to `maxWidth`, drawn with its vertical center on
/// `centerY` (in points from the bottom edge).
func draw(_ text: NSAttributedString, centerY: CGFloat, maxWidth: CGFloat) {
    var size = text.size()
    var drawn = text
    if size.width > maxWidth {
        let scale = maxWidth / size.width
        let scaled = NSMutableAttributedString(attributedString: text)
        scaled.enumerateAttribute(.font, in: NSRange(location: 0, length: scaled.length)) { value, range, _ in
            if let font = value as? NSFont {
                scaled.addAttribute(.font, value: NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scale)!, range: range)
            }
        }
        drawn = scaled
        size = scaled.size()
    }
    drawn.draw(at: NSPoint(x: textLeft, y: centerY - size.height / 2))
}

func render(textColor: NSColor) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(canvas.width), pixelsHigh: Int(canvas.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // The app icon's tile and gradient: dark at the bottom (#200D3C) to
    // lighter at the top (#3F2F57).
    let radius = tile.width * 0.225
    NSGradient(
        starting: NSColor(calibratedRed: 0.125, green: 0.051, blue: 0.235, alpha: 1),
        ending: NSColor(calibratedRed: 0.247, green: 0.184, blue: 0.341, alpha: 1))!
        .draw(in: NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius), angle: 90)
    let side = tile.width * LogoArtwork.iconHeightFraction
    let markRect = NSRect(x: tile.midX - side / 2, y: tile.midY - side / 2, width: side, height: side)
    let context = NSGraphicsContext.current!.cgContext
    context.addPath(LogoMark.path(fitting: markRect))
    context.setFillColor(NSColor.white.cgColor)
    context.fillPath()

    // The name, and below it owner/repository with the repository in bold.
    let heavy = NSFont(name: "HelveticaNeue-Bold", size: 92) ?? .boldSystemFont(ofSize: 92)
    let light = NSFont(name: "HelveticaNeue", size: 66) ?? .systemFont(ofSize: 66)
    let bold = NSFont(name: "HelveticaNeue-Bold", size: 66) ?? .boldSystemFont(ofSize: 66)
    draw(
        NSAttributedString(string: title, attributes: [.font: heavy, .foregroundColor: textColor]),
        centerY: canvas.height - 255, maxWidth: textMaxWidth)
    let line = NSMutableAttributedString(string: owner, attributes: [.font: light, .foregroundColor: textColor])
    line.append(NSAttributedString(string: repository, attributes: [.font: bold, .foregroundColor: textColor]))
    draw(line, centerY: canvas.height - 395, maxWidth: textMaxWidth)

    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("docs/images")
try fm.createDirectory(at: output, withIntermediateDirectories: true)

for (name, color) in [
    ("banner-black-text.png", NSColor(calibratedWhite: 0.082, alpha: 1)),
    ("banner-white-text.png", NSColor.white),
] {
    let url = output.appendingPathComponent(name)
    try render(textColor: color).write(to: url)
    print("wrote \(url.path)")
}
