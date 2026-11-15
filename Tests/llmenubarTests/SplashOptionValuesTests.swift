// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest

@testable import llmenubar

final class SplashOptionValuesTests: XCTestCase {
    func testByteCountsFollowTheServerRules() {
        XCTAssertEqual(SplashOptionValues.byteCount("1"), 1)
        XCTAssertEqual(SplashOptionValues.byteCount("1024"), 1_024)
        XCTAssertEqual(SplashOptionValues.byteCount("28G"), 28 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(SplashOptionValues.byteCount("28g"), 28 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(SplashOptionValues.byteCount("28GB"), 28 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(SplashOptionValues.byteCount("28GiB"), 28 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(SplashOptionValues.byteCount("2.5G"), Decimal(2_684_354_560))
        XCTAssertEqual(SplashOptionValues.byteCount("512M"), 512 * 1_024 * 1_024)
        XCTAssertEqual(SplashOptionValues.byteCount("1200M"), 1_200 * 1_024 * 1_024)
        XCTAssertEqual(SplashOptionValues.byteCount("1.5K"), 1_536)
    }

    func testByteCountsRefuseWhatTheServerRefuses() {
        for text in ["", "0", "0G", "-1G", "G", "1.5", "1.5.2G", "1,5G", "28 G x", "1e3", "B", "28T", "auto",
                     "99999999999999999999G"] {
            XCTAssertNil(SplashOptionValues.byteCount(text), text)
        }
    }

    func testDurations() {
        XCTAssertEqual(SplashOptionValues.seconds("30m"), 1_800)
        XCTAssertEqual(SplashOptionValues.seconds("2h"), 7_200)
        XCTAssertEqual(SplashOptionValues.seconds("90s"), 90)
        XCTAssertEqual(SplashOptionValues.seconds("600"), 600)
        XCTAssertEqual(SplashOptionValues.seconds("0.5m"), 30)
        for text in ["", "0", "0m", "-5m", "m", "10x", "1d", "off", "1m30s"] {
            XCTAssertNil(SplashOptionValues.seconds(text), text)
        }
    }

    func testContextTokens() {
        XCTAssertEqual(SplashOptionValues.contextTokens("100K"), 102_400)
        XCTAssertEqual(SplashOptionValues.contextTokens("100k"), 102_400)
        XCTAssertEqual(SplashOptionValues.contextTokens("1M"), 1_000_000)
        XCTAssertEqual(SplashOptionValues.contextTokens("262144"), 262_144)
        XCTAssertEqual(SplashOptionValues.contextTokens("1010000"), 1_010_000)
        for text in ["", "0", "1010001", "1011K", "2M", "K", "1.5K", "-1", "auto", "99999999999999999999"] {
            XCTAssertNil(SplashOptionValues.contextTokens(text), text)
        }
    }

    func testWholeNumbersAndDecimals() {
        XCTAssertEqual(SplashOptionValues.wholeNumber("0"), 0)
        XCTAssertEqual(SplashOptionValues.wholeNumber("32"), 32)
        XCTAssertNil(SplashOptionValues.wholeNumber("-1"))
        XCTAssertNil(SplashOptionValues.wholeNumber("1.5"))
        XCTAssertNil(SplashOptionValues.wholeNumber(""))
        XCTAssertEqual(SplashOptionValues.nonnegativeDecimal("0.5"), 0.5)
        XCTAssertEqual(SplashOptionValues.nonnegativeDecimal("0"), 0)
        XCTAssertEqual(SplashOptionValues.nonnegativeDecimal("2"), 2)
        XCTAssertNil(SplashOptionValues.nonnegativeDecimal("-0.5"))
        XCTAssertNil(SplashOptionValues.nonnegativeDecimal("nan"))
        XCTAssertNil(SplashOptionValues.nonnegativeDecimal("inf"))
        XCTAssertNil(SplashOptionValues.nonnegativeDecimal("1,5"))
    }

    func testAutoIsRecognizedInAnyCase() {
        XCTAssertTrue(SplashOptionValues.isAuto("auto"))
        XCTAssertTrue(SplashOptionValues.isAuto(" AUTO "))
        XCTAssertFalse(SplashOptionValues.isAuto("automatic"))
    }

    func testListsAreSplitAtCommasAndTrimmed() {
        XCTAssertEqual(SplashOptionValues.items("a, b ,, c"), ["a", "b", "c"])
        XCTAssertEqual(SplashOptionValues.items(""), [])
        XCTAssertEqual(SplashOptionValues.items(" , "), [])
    }

    func testModelAliases() {
        for name in ["gpt-4o", "my/model", "qwen:27b", "a.b"] {
            XCTAssertTrue(SplashOptionValues.isModelAlias(name), name)
        }
        for name in ["", "has space", "a?b", "a#b", "a%b", "a\\b", "/x", "x/", "a//b", ".", "..", "a/../b", "tab\tname", "-x", "--model"] {
            XCTAssertFalse(SplashOptionValues.isModelAlias(name), name)
        }
    }

    func testOrigins() {
        for origin in ["*", "http://localhost:3000", "https://example.com", "tauri://localhost", "app+x://host", "http://[::1]:8000", "http://a.example:65535"] {
            XCTAssertTrue(SplashOptionValues.isOrigin(origin), origin)
        }
        for origin in ["", "localhost", "http://", "http://a/b", "://x", "http://a b", "1http://x", "http://a?x=1", "http://a#f", "http://u@a", "http://*.a.com", "http://a:", "http://a:port", "http://a:70000", "http://a:1:2", "http://[::1", "http://:80", "http://é.example"] {
            XCTAssertFalse(SplashOptionValues.isOrigin(origin), origin)
        }
    }
}
