// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest

@testable import llmenubar

final class EnvironmentAndPlacementTests: XCTestCase {
    func testAssignmentsAreReadLineByLine() {
        let text = """
        SPLASH_CRASH_TRACE=1
          INDENTED = spaced value
        # a comment
        EMPTY=
        URL=http://x/?a=b
        """
        XCTAssertEqual(
            EnvironmentText.parse(text),
            [
                .init(name: "SPLASH_CRASH_TRACE", value: "1"),
                .init(name: "INDENTED", value: "spaced value"),
                .init(name: "EMPTY", value: ""),
                .init(name: "URL", value: "http://x/?a=b"),
            ]
        )
        XCTAssertNil(EnvironmentText.firstError(in: text))
    }

    func testTheFirstBadLineIsNamed() {
        XCTAssertEqual(EnvironmentText.firstError(in: "A=1\nnope\nalso nope"), "“nope” is not NAME=VALUE.")
        XCTAssertTrue(EnvironmentText.firstError(in: "9X=1")?.contains("9X") == true)
        XCTAssertTrue(EnvironmentText.firstError(in: "SPLASH_API_KEY=x")?.contains("API key") == true)
        XCTAssertEqual(EnvironmentText.parse("good=1\nbad line"), [.init(name: "good", value: "1")])
    }

    func testNames() {
        for name in ["A", "_a", "SPLASH_CRASH_TRACE", "a1_b2"] { XCTAssertTrue(EnvironmentText.isValidName(name), name) }
        for name in ["", "1a", "a-b", "a b", "é", "a.b"] { XCTAssertFalse(EnvironmentText.isValidName(name), name) }
    }

    func testGeneratedKeysAreValidDistinctAndVisible() {
        let keys = (0..<50).map { _ in APIKeyGenerator.make() }
        XCTAssertEqual(Set(keys).count, 50)
        for key in keys {
            XCTAssertTrue(key.hasPrefix("llm-"))
            XCTAssertEqual(key.count, 4 + 32)
            XCTAssertFalse(key.unicodeScalars.contains { $0.value <= 32 || $0.value >= 127 })
        }
        var config = ServerConfiguration.Config()
        config.splashPath = "/opt/homebrew/bin/splash"
        config.huggingFaceModel = "a/b"
        config.apiKey = keys[0]
        XCTAssertNil(config.validationErrors()[.apiKey])
    }

    // MARK: Status item placement

    private func makeDefaults() throws -> UserDefaults {
        let name = "llmenubar-placement-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    func testAFirstLaunchGetsAStartingPositionNearTheRightEdge() throws {
        let defaults = try makeDefaults()
        XCTAssertTrue(StatusItemPlacement.seedInitialPosition(in: defaults))
        XCTAssertEqual(
            defaults.double(forKey: "NSStatusItem Preferred Position LLMenuBar"),
            Double(StatusItemPlacement.initialDistanceFromRight)
        )
    }

    func testAPositionTheUserChoseIsNeverOverwritten() throws {
        let defaults = try makeDefaults()
        defaults.set(612.0, forKey: StatusItemPlacement.defaultsKey)
        XCTAssertFalse(StatusItemPlacement.seedInitialPosition(in: defaults))
        XCTAssertEqual(defaults.double(forKey: StatusItemPlacement.defaultsKey), 612.0)
        XCTAssertFalse(StatusItemPlacement.seedInitialPosition(in: defaults))
    }
}
