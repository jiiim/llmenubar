// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest
@testable import llmenubar

final class SetupWindowSizingTests: XCTestCase {
    func testStepsThatFitAreShownInFull() {
        XCTAssertEqual(SetupWindowSizing.scrollHeight(steps: 700, buttons: 60, tallest: 1200), 700)
        XCTAssertFalse(SetupWindowSizing.scrolls(steps: 700, buttons: 60, tallest: 1200))
    }

    func testStepsTallerThanTheScreenScrollAboveTheButtons() {
        XCTAssertEqual(SetupWindowSizing.scrollHeight(steps: 900, buttons: 60, tallest: 600), 540)
        XCTAssertTrue(SetupWindowSizing.scrolls(steps: 900, buttons: 60, tallest: 600))
    }

    func testStepsThatExactlyFitDoNotScroll() {
        XCTAssertEqual(SetupWindowSizing.scrollHeight(steps: 540, buttons: 60, tallest: 600), 540)
        XCTAssertFalse(SetupWindowSizing.scrolls(steps: 540, buttons: 60, tallest: 600))
    }

    func testAScreenShorterThanTheButtonsLeavesNoNegativeHeight() {
        XCTAssertEqual(SetupWindowSizing.scrollHeight(steps: 900, buttons: 60, tallest: 40), 0)
    }
}
