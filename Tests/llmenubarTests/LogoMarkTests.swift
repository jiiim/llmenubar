// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import AppKit
import XCTest

@testable import llmenubar

/// These hold for any artwork `LogoArtwork` supplies, the placeholder square
/// and the official logo alike, so they pass in both kinds of build.
final class LogoMarkTests: XCTestCase {
    private func assertEqual(_ a: CGRect, _ b: CGRect, accuracy: CGFloat = 0.001,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.minX, b.minX, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.minY, b.minY, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: accuracy, file: file, line: line)
    }

    // `boundingBox` on a CGPath with arcs can overshoot (by 0.07 on a 0.5 radius arc);
    // `boundingBoxOfPath` includes control points, which on these arcs lie within 0.001 of the curve.
    func testThePathDataParsesIntoOutlinesThatFillTheirGrid() {
        let paths = LogoMark.gridPaths()
        XCTAssertFalse(paths.isEmpty)
        let bounds = paths.map(\.boundingBoxOfPath).reduce(CGRect.null) { $0.union($1) }
        assertEqual(bounds, CGRect(x: 0, y: 0, width: LogoMark.gridWidth, height: LogoMark.gridHeight), accuracy: 0.01)
    }

    func testTheParserReadsLinesAndSubpaths() {
        let paths = LogoMark.gridPaths(from: "M0 0 H2 V1 H1 V3 H0 Z M4 0 L6 0 L5 2 Z")
        XCTAssertEqual(paths.count, 2)
        assertEqual(paths[0].boundingBoxOfPath, CGRect(x: 0, y: 0, width: 2, height: 3))
        assertEqual(paths[1].boundingBoxOfPath, CGRect(x: 4, y: 0, width: 2, height: 2))
        XCTAssertTrue(paths[0].contains(CGPoint(x: 0.5, y: 2)), "the upright of the L")
        XCTAssertFalse(paths[0].contains(CGPoint(x: 1.5, y: 2)), "the notch beside it")
    }

    func testTheParserReadsArcsInTheDirectionTheFlagSays() {
        // Left to right with sweep 1 goes over the top in y-down terms.
        let over = LogoMark.gridPaths(from: "M0 1 A1 1 0 0 1 2 1 Z")[0]
        assertEqual(over.boundingBoxOfPath, CGRect(x: 0, y: 0, width: 2, height: 1), accuracy: 0.01)
        XCTAssertTrue(over.contains(CGPoint(x: 1, y: 0.5)))
        XCTAssertFalse(over.contains(CGPoint(x: 1, y: 1.5)))
        // Sweep 0 goes underneath.
        let under = LogoMark.gridPaths(from: "M0 1 A1 1 0 0 0 2 1 Z")[0]
        assertEqual(under.boundingBoxOfPath, CGRect(x: 0, y: 1, width: 2, height: 1), accuracy: 0.01)
        // A rounded end: a bar 1 thick with a half circle cap of radius 0.5.
        let capped = LogoMark.gridPaths(from: "M0 0 H3 V1 H0 Z M4 0.5 A0.5 0.5 0 0 1 5 0.5 V3 H4 Z")
        XCTAssertEqual(capped.count, 2)
        assertEqual(capped[1].boundingBoxOfPath, CGRect(x: 4, y: 0, width: 1, height: 3), accuracy: 0.01)
        XCTAssertFalse(capped[1].contains(CGPoint(x: 4.02, y: 0.05)), "the corner is rounded off")
        XCTAssertTrue(capped[1].contains(CGPoint(x: 4.5, y: 0.05)), "the top of the cap")
    }

    func testThePathFitsItsRectangleAndKeepsItsProportions() {
        let rect = CGRect(x: 10, y: 20, width: 240, height: 120)
        let scale = min(rect.width / LogoMark.gridWidth, rect.height / LogoMark.gridHeight)
        let bounds = LogoMark.path(fitting: rect).boundingBoxOfPath
        XCTAssertEqual(bounds.width, LogoMark.gridWidth * scale, accuracy: 0.01)
        XCTAssertEqual(bounds.height, LogoMark.gridHeight * scale, accuracy: 0.01)
        XCTAssertEqual(bounds.midX, rect.midX, accuracy: 0.01)
        XCTAssertEqual(bounds.midY, rect.midY, accuracy: 0.01)
    }

    func testThePathIsDrawnWithYUp() {
        // Grid y grows downward, AppKit's upward: a strip at the top of the
        // grid must land at the top of the rectangle.
        let rect = CGRect(x: 0, y: 0, width: 200, height: 400)
        let path = LogoMark.path(fitting: rect, data: "M0 0 H2 V1 H0 Z", gridWidth: 2, gridHeight: 4)
        assertEqual(path.boundingBoxOfPath, CGRect(x: 0, y: 300, width: 200, height: 100), accuracy: 0.01)
    }

    @MainActor
    func testTheMenuBarImageIsATemplateWithTheMarksProportions() {
        let image = LogoMark.menuBarImage
        XCTAssertTrue(image.isTemplate, "a template follows the menu bar's color")
        XCTAssertEqual(image.size.height, LogoArtwork.menuBarHeight, accuracy: 0.001)
        XCTAssertEqual(image.size.width / image.size.height, LogoMark.gridWidth / LogoMark.gridHeight, accuracy: 0.001)
    }

    func testTheIconMarkFitsInsideItsTile() {
        XCTAssertGreaterThan(LogoArtwork.iconHeightFraction, 0.1)
        XCTAssertLessThan(LogoArtwork.iconHeightFraction, 0.8)
    }

    func testDimmingLeavesTheLogoVisibleButClearlyLighter() {
        XCTAssertGreaterThan(StatusItemAppearance.dimmedAlpha, 0.5)
        XCTAssertLessThan(StatusItemAppearance.dimmedAlpha, 1)
    }
}
