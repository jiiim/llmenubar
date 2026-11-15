// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import llmenubar

@MainActor
final class StatusItemRendererTests: XCTestCase {
    private let scale: CGFloat = 4

    /// The image drawn at `scale` times its size, to read its ink.
    private func bitmap(of image: NSImage) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(image.size.width * scale), pixelsHigh: Int(image.size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        return rep
    }

    /// The rows and columns with ink in `columns`, as points from the top-left.
    private func ink(in rep: NSBitmapImageRep, columns: Range<Int>) -> (top: CGFloat, bottom: CGFloat, left: CGFloat, right: CGFloat)? {
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in columns where x < rep.pixelsWide {
                if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.4 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return (CGFloat(minY) / scale, CGFloat(rep.pixelsHigh - 1 - maxY) / scale, CGFloat(minX) / scale, CGFloat(rep.pixelsWide - 1 - maxX) / scale)
    }

    func testTheDigitsHaveTheSameSpaceAboveAndBelow() throws {
        let image = StatusItemRenderer.image(rate: "88.8")
        let rep = try bitmap(of: image)
        let start = Int((LogoMark.menuBarImage.size.width + StatusItemRenderer.logoGap) * scale)
        // The first three columns hold the digits "88", which have no descender
        // or ascender beyond the digit height.
        let digits = try XCTUnwrap(ink(in: rep, columns: start..<(start + Int(12 * scale))))
        XCTAssertEqual(digits.top, digits.bottom, accuracy: 0.3, "space above \(digits.top) pt, below \(digits.bottom) pt")
    }

    func testTheLogoIsCenteredToo() throws {
        let image = StatusItemRenderer.image(rate: "88.8")
        let rep = try bitmap(of: image)
        let logo = try XCTUnwrap(ink(in: rep, columns: 0..<Int(LogoMark.menuBarImage.size.width * scale)))
        XCTAssertEqual(logo.top, logo.bottom, accuracy: 0.3)
    }

    func testNothingIsWastedAtTheEdges() throws {
        let image = StatusItemRenderer.image(rate: "88.8")
        let rep = try bitmap(of: image)
        let all = try XCTUnwrap(ink(in: rep, columns: 0..<rep.pixelsWide))
        XCTAssertLessThanOrEqual(all.left, 0.3, "the logo starts at the left edge")
        XCTAssertLessThanOrEqual(all.right, 1.0, "the s ends at the right edge, within a point")
    }

    func testTheLogoAloneHasNoSpareSpace() throws {
        let rep = try bitmap(of: LogoMark.menuBarImage)
        let logo = try XCTUnwrap(ink(in: rep, columns: 0..<rep.pixelsWide))
        XCTAssertLessThanOrEqual(logo.left, 0.3)
        XCTAssertLessThanOrEqual(logo.right, 0.3)
    }

    /// The widths of the empty runs between ink, in points, looking only at
    /// the pixel rows `rows`.
    private func gaps(in rep: NSBitmapImageRep, rows: Range<Int>) -> [CGFloat] {
        var result: [CGFloat] = []
        var run = 0
        var seenInk = false
        for x in 0..<rep.pixelsWide {
            let inked = rows.contains { (rep.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0.4 }
            if inked {
                if seenInk && run > 0 { result.append(CGFloat(run) / scale) }
                run = 0
                seenInk = true
            } else {
                run += 1
            }
        }
        return result
    }

    func testTheUnitsSitAsFarFromTheDigitsAsTheDigitsFromTheLogo() throws {
        let rep = try bitmap(of: StatusItemRenderer.image(rate: "88.8"))
        // The logo and the digits face each other across the whole height.
        let logoToDigits = try XCTUnwrap(gaps(in: rep, rows: 0..<rep.pixelsHigh).first)
        XCTAssertEqual(logoToDigits, StatusItemRenderer.unitsGap, accuracy: 0.3)
        // The `t` is set by its stem; its crossbar reaches left of that.
        let t = CTLineCreateWithAttributedString(NSAttributedString(
            string: "t", attributes: [.font: NSFont.menuBarFont(ofSize: 0)]
        ))
        let overhang = StatusItemRenderer.unitsStemLeft - CTLineGetImageBounds(t, nil).minX
        XCTAssertGreaterThan(overhang, 0.2)
        let all = gaps(in: rep, rows: 0..<rep.pixelsHigh)
        // The last two gaps are inside `t/s`; the one before them is the digits'.
        let digitsToCrossbar = try XCTUnwrap(all.dropLast(2).last)
        XCTAssertEqual(digitsToCrossbar + overhang, StatusItemRenderer.unitsGap, accuracy: 0.3, "\(all)")
    }

    func testTheItemKeepsOneWidthWhateverTheRate() {
        let widths = [ServerPerformance.idle, .init(phase: .generation, tokensPerSecond: 8.4),
                      .init(phase: .generation, tokensPerSecond: 92.8), .init(phase: .prefill, tokensPerSecond: 629),
                      .init(phase: .prefill, tokensPerSecond: 12_345)]
            .map { StatusItemRenderer.image(rate: $0.menuBarRate).size.width }
        XCTAssertEqual(Set(widths).count, 1, "\(widths)")
    }

    func testTheImageIsATemplateAndSaysWhatItShows() {
        let image = StatusItemRenderer.image(rate: " 92.8")
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.accessibilityDescription, "LLMenuBar 92.8 t/s")
    }
}
