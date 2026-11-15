// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import CoreGraphics

/// The placeholder mark: a filled square, the glyph U+25A0 BLACK SQUARE.
///
/// This is the one file that defines how the mark looks. Builds from this
/// repository use it. The official release builds replace this file and
/// `Resources/AppIcon.icns` with the LLMenuBar logo, which is not part of this
/// repository and is not licensed under the MIT license; see TRADEMARKS.md.
///
/// A replacement keeps these members. `pathData` is SVG path data on a grid
/// `gridWidth` by `gridHeight` units, y down, using the absolute `M`, `H`, `V`,
/// `L` and `Z` commands.
enum LogoArtwork {
    static let pathData = "M0 0 H1 V1 H0 Z"
    static let gridWidth: CGFloat = 1
    static let gridHeight: CGFloat = 1

    /// Height of the menu-bar glyph in points.
    static let menuBarHeight: CGFloat = 12

    /// How tall the mark is in the app icon, as a fraction of the tile's width.
    static let iconHeightFraction: CGFloat = 0.34
}
