// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import AppKit
import CoreText

/// The menu-bar item while it shows the speed: the logo and the rate drawn
/// into one template image.
///
/// The status button lays out its own title, and where it puts the text is the
/// system's choice: the digits sat above the middle of the item, with more room
/// below them than above, and the item kept padding on both sides that the
/// button's layout cannot remove. Drawing the whole thing as an image fixes the
/// position of every part, and the system only centers the image.
///
/// The rate is drawn in four fixed columns, so the item keeps one width as the
/// number changes, and `t/s` stays where it is. The fonts are the menu bar's own size, with fixed-pitch
/// digits and the menu-bar face for the units.
@MainActor
enum StatusItemRenderer {
    private static let menuFont = NSFont.menuBarFont(ofSize: 0)
    private static let fieldFont = NSFont.monospacedSystemFont(
        ofSize: menuFont.pointSize,
        weight: .regular
    )

    /// Space between the logo and the first column of the rate.
    static let logoGap: CGFloat = 3

    /// What the item adds to the image's width. None: the image fills the
    /// item, so the only space left of the logo and right of the `s` is the
    /// margin macOS puts around every status item.
    static let horizontalPadding: CGFloat = 0

    /// Space between the last digit and the `t` of `t/s`: the visible space
    /// between the logo and the first digit, which is `logoGap` plus the
    /// digit's own left side bearing.
    static var unitsGap: CGFloat {
        logoGap + CTLineGetImageBounds(CTLineCreateWithAttributedString(rateText("8")), nil).minX
    }

    /// Where the stem of the `t` starts, from the start of its line. The `t`'s
    /// crossbar reaches left of its stem, and the eye measures the space to
    /// the stem, so that is the edge the gap is set from. Read from the
    /// glyph's own outline, a row of ink a little above the baseline.
    static var unitsStemLeft: CGFloat {
        let scale: CGFloat = 16
        let height = Int(ceil(menuFont.capHeight * 2 * scale)), width = Int(ceil(menuFont.pointSize * scale))
        let baseline = CGFloat(height) / 4
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }
        context.setFillColor(gray: 1, alpha: 1)
        context.scaleBy(x: scale, y: scale)
        context.textPosition = CGPoint(x: 0, y: baseline / scale)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "t", attributes: [.font: menuFont, .foregroundColor: NSColor.white])), context)
        guard let data = context.data else { return 0 }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        // Rows are stored top first: a row 15 percent of the cap height above the baseline.
        let row = height - 1 - Int(baseline + menuFont.capHeight * 0.15 * scale)
        guard let first = (0..<width).first(where: { bytes[row * width + $0] > 127 }) else { return 0 }
        return CGFloat(first) / scale
    }

    /// The rate in four fixed columns.
    static func rateText(_ rate: String) -> NSAttributedString {
        NSAttributedString(string: rate, attributes: [.font: fieldFont, .foregroundColor: NSColor.black])
    }

    private static let unitsText = NSAttributedString(
        string: "t/s",
        attributes: [.font: menuFont, .foregroundColor: NSColor.black]
    )

    /// Where `t/s` starts, measured from the start of the rate. Fixed, so the
    /// units do not move as the digits change: the stem of its `t` is `unitsGap` from the
    /// ink of an `8`, the widest digit.
    private static func unitsOffset(rateLine: CTLine) -> CGFloat {
        let eight = CTLineCreateWithAttributedString(rateText("8"))
        let rightBearing = CTLineGetTypographicBounds(eight, nil, nil, nil) - CTLineGetImageBounds(eight, nil).maxX
        let unitsLeftBearing = unitsStemLeft
        let columns = CGFloat(CTLineGetTypographicBounds(rateLine, nil, nil, nil))
        return columns - rightBearing + unitsGap - unitsLeftBearing
    }

    /// Where the digits sit, measured from the bottom of an image of `height`:
    /// their tops and bottoms are the same distance from its edges.
    static func baseline(forHeight height: CGFloat) -> CGFloat {
        height / 2 - fieldFont.capHeight / 2
    }

    static func image(rate: String) -> NSImage {
        let logo = LogoMark.menuBarImage
        let line = CTLineCreateWithAttributedString(rateText(rate))
        let units = CTLineCreateWithAttributedString(unitsText)
        let unitsX = unitsOffset(rateLine: line)
        // The ink, not the advance: the last glyph's side bearing is space the
        // item does not need.
        let textWidth = ceil(unitsX + CTLineGetImageBounds(units, nil).maxX)
        let canvas = NSSize(
            width: logo.size.width + logoGap + textWidth,
            height: max(logo.size.height, ceil(fieldFont.ascender - fieldFont.descender))
        )
        let image = NSImage(size: canvas, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            logo.draw(in: NSRect(x: 0, y: (rect.height - logo.size.height) / 2, width: logo.size.width, height: logo.size.height))
            context.setFillColor(NSColor.black.cgColor)
            let origin = CGPoint(x: logo.size.width + logoGap, y: baseline(forHeight: rect.height))
            context.textPosition = origin
            CTLineDraw(line, context)
            context.textPosition = CGPoint(x: origin.x + unitsX, y: origin.y)
            CTLineDraw(units, context)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "LLMenuBar \(rate.trimmingCharacters(in: .whitespaces)) t/s"
        return image
    }
}
