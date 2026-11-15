// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import AppKit

/// Draws the app's mark from `LogoArtwork`, which holds the geometry.
///
/// The parser, the fitting and the menu-bar image here are generic: they work
/// on whatever outline `LogoArtwork` supplies. The icon generator (`make icon`)
/// compiles this file too, so the app icon and the menu-bar glyph cannot drift
/// apart.
enum LogoMark {
    static var pathData: String { LogoArtwork.pathData }
    static var gridWidth: CGFloat { LogoArtwork.gridWidth }
    static var gridHeight: CGFloat { LogoArtwork.gridHeight }

    /// The outlines in grid units, y down, one path per subpath. Reads the
    /// absolute `M`, `H`, `V`, `L`, `A` and `Z` commands the path data uses.
    /// An arc is circular: its radius is the first number, the rotation is
    /// ignored, and the flags and end point follow the SVG rules.
    static func gridPaths(from data: String = pathData) -> [CGPath] {
        var paths: [CGPath] = []
        var current: CGMutablePath?
        var point = CGPoint.zero

        func finishSubpath() {
            if let current { paths.append(current) }
            current = nil
        }

        func apply(_ command: Character, _ n: [CGFloat]) {
            switch command {
            case "M":
                finishSubpath()
                point = CGPoint(x: n[0], y: n[1])
                let path = CGMutablePath()
                path.move(to: point)
                current = path
            case "H":
                point.x = n[0]; current?.addLine(to: point)
            case "V":
                point.y = n[0]; current?.addLine(to: point)
            case "L":
                point = CGPoint(x: n[0], y: n[1]); current?.addLine(to: point)
            case "A":
                let end = CGPoint(x: n[5], y: n[6])
                if let current {
                    addArc(to: current, from: point, end: end, radius: n[0], largeArc: n[3] != 0, sweep: n[4] != 0)
                }
                point = end
            case "Z":
                current?.closeSubpath()
                finishSubpath()
            default: break
            }
        }

        var command: Character?
        var numbers: [CGFloat] = []
        var token = ""
        func finishNumber() {
            if let value = Double(token) { numbers.append(CGFloat(value)) }
            token = ""
        }
        func finishCommand() {
            if let command { apply(command, numbers) }
            numbers = []
        }
        for character in data {
            if character.isLetter {
                finishNumber()
                finishCommand()
                command = character
            } else if character == " " || character == "\n" || character == "," {
                finishNumber()
            } else {
                token.append(character)
            }
        }
        finishNumber()
        finishCommand()
        finishSubpath()
        return paths
    }

    /// Adds the circular arc of `radius` from `start` to `end` that the SVG
    /// arc flags pick out. A radius too small to span the two points grows to
    /// the smallest that does.
    private static func addArc(
        to path: CGMutablePath, from start: CGPoint, end: CGPoint,
        radius: CGFloat, largeArc: Bool, sweep: Bool
    ) {
        let halfDX = (start.x - end.x) / 2, halfDY = (start.y - end.y) / 2
        let halfChordSquared = halfDX * halfDX + halfDY * halfDY
        guard halfChordSquared > 0 else { return }
        let radius = max(radius, halfChordSquared.squareRoot())
        let offset = ((radius * radius - halfChordSquared) / halfChordSquared).squareRoot()
        let sign: CGFloat = largeArc == sweep ? -1 : 1
        let center = CGPoint(
            x: sign * offset * halfDY + (start.x + end.x) / 2,
            y: -sign * offset * halfDX + (start.y + end.y) / 2
        )
        // Angles here grow with y pointing down, which is what an SVG sweep of
        // 1 means; CGPath's `clockwise` is the opposite sense of that.
        path.addArc(
            center: center, radius: radius,
            startAngle: atan2(start.y - center.y, start.x - center.x),
            endAngle: atan2(end.y - center.y, end.x - center.x),
            clockwise: !sweep
        )
    }

    /// The mark as a path that fits `rect` (y up, as AppKit draws), keeping its
    /// proportions and centered in the rectangle. `data` and the grid size
    /// default to the artwork's own.
    static func path(
        fitting rect: CGRect,
        data: String = pathData,
        gridWidth: CGFloat = gridWidth,
        gridHeight: CGFloat = gridHeight
    ) -> CGPath {
        let scale = min(rect.width / gridWidth, rect.height / gridHeight)
        let origin = CGPoint(
            x: rect.midX - gridWidth * scale / 2,
            y: rect.midY - gridHeight * scale / 2
        )
        // Grid y grows downward, AppKit's upward.
        let transform = CGAffineTransform(
            a: scale, b: 0, c: 0, d: -scale,
            tx: origin.x, ty: origin.y + gridHeight * scale
        )
        let path = CGMutablePath()
        for gridPath in gridPaths(from: data) {
            path.addPath(gridPath, transform: transform)
        }
        return path
    }

    /// The mark for the menu bar: a template image, so macOS draws it in the
    /// menu bar's own color on any wallpaper and in dark or light mode.
    @MainActor
    static let menuBarImage: NSImage = {
        let height = LogoArtwork.menuBarHeight
        let size = NSSize(width: height * gridWidth / gridHeight, height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(path(fitting: rect))
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
