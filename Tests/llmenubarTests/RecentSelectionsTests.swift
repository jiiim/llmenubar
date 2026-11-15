// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest

@testable import llmenubar

final class RecentSelectionsTests: XCTestCase {
    func testRecordPutsTheNewestFirstAndKeepsOneEntryPerPath() {
        var recents = RecentSelections()
        recents.record("/a", for: .model)
        recents.record("/b", for: .model)
        recents.record("/a", for: .model)
        XCTAssertEqual(recents.recentPaths(for: .model), ["/a", "/b"])
    }

    func testTheListIsCappedAtFive() {
        var recents = RecentSelections()
        for index in 0..<8 { recents.record("/m\(index)", for: .model) }
        XCTAssertEqual(recents.recentPaths(for: .model), ["/m7", "/m6", "/m5", "/m4", "/m3"])
    }

    func testTheOutgoingSelectionSurvivesAFullList() {
        var recents = RecentSelections()
        for index in 0..<5 { recents.record("/m\(index)", for: .model) }
        // /m0 is the oldest; replacing it keeps it as the way back.
        recents.record("/new", replacing: "/m0", for: .model)
        XCTAssertEqual(recents.recentPaths(for: .model).first, "/new")
        XCTAssertTrue(recents.recentPaths(for: .model).contains("/m0"))
        XCTAssertEqual(recents.recentPaths(for: .model).count, 5)
    }

    func testEmptyAndBlankPathsAreNotRemembered() {
        var recents = RecentSelections()
        recents.record("", for: .model)
        recents.record("   ", for: .splash)
        recents.seed("", for: .draft)
        XCTAssertEqual(recents, RecentSelections())
    }

    func testListsAreKeptPerField() {
        var recents = RecentSelections()
        recents.record("/splash", for: .splash)
        recents.record("/model", for: .model)
        XCTAssertEqual(recents.recentPaths(for: .splash), ["/splash"])
        XCTAssertEqual(recents.recentPaths(for: .model), ["/model"])
        XCTAssertEqual(recents.recentPaths(for: .visionProjector), [])
        recents.clear(.splash)
        XCTAssertEqual(recents.recentPaths(for: .splash), [])
        XCTAssertEqual(recents.recentPaths(for: .model), ["/model"])
    }

    func testTwoSpellingsOfOneFileAreOneEntryAndTheNewerWins() {
        let key: (String) -> String = { $0.replacingOccurrences(of: "~", with: "/Users/me") }
        var recents = RecentSelections()
        recents.record("~/m.gguf", for: .model, fileKey: key)
        recents.record("/Users/me/m.gguf", for: .model, fileKey: key)
        XCTAssertEqual(recents.recentPaths(for: .model), ["/Users/me/m.gguf"])
    }

    func testSeedAddsAtTheEndWithoutDisturbingOrder() {
        var recents = RecentSelections()
        recents.record("/a", for: .model)
        recents.seed("/b", for: .model)
        recents.seed("/a", for: .model)
        XCTAssertEqual(recents.recentPaths(for: .model), ["/a", "/b"])
    }

    func testSeedTakesTheOldestSlotWhenFull() {
        var recents = RecentSelections()
        for index in 0..<5 { recents.record("/m\(index)", for: .model) }
        recents.seed("/current", for: .model)
        XCTAssertEqual(recents.recentPaths(for: .model).last, "/current")
        XCTAssertEqual(recents.recentPaths(for: .model).count, 5)
    }

    func testPruneDropsWhatTheJudgeRejectsAndEmptiesLists() {
        var recents = RecentSelections()
        recents.record("/gone", for: .model)
        recents.record("/kept", for: .model)
        recents.record("/gone", for: .draft)
        recents.prune { _, path in path == "/gone" }
        XCTAssertEqual(recents.recentPaths(for: .model), ["/kept"])
        XCTAssertEqual(recents.recentPaths(for: .draft), [])
    }

    func testDecodingToleratesMissingKeysAndClampsOversizedLists() throws {
        XCTAssertEqual(try JSONDecoder().decode(RecentSelections.self, from: Data("{}".utf8)), RecentSelections())
        let oversized = #"{"lists":{"model":["/1","/2","/3","/4","/5","/6","/7"],"unknownField":["/x"]}}"#
        let decoded = try JSONDecoder().decode(RecentSelections.self, from: Data(oversized.utf8))
        XCTAssertEqual(decoded.recentPaths(for: .model), ["/1", "/2", "/3", "/4", "/5"])
    }

    func testRoundTrip() throws {
        var recents = RecentSelections()
        recents.record("/a", for: .splash)
        recents.record("/b", for: .model)
        let data = try JSONEncoder().encode(recents)
        XCTAssertEqual(try JSONDecoder().decode(RecentSelections.self, from: data), recents)
    }

    // MARK: Entries of a configuration

    func testHubConfigurationsRememberTheExecutableAndTheModel() {
        var config = ServerConfiguration.Config()
        config.splashPath = "/opt/homebrew/bin/splash"
        config.huggingFaceModel = "a/b:Q4"
        config.modelPath = "/stale/m.gguf"
        XCTAssertEqual(
            RecentSelections.entries(in: config),
            [
                RecentSelections.Entry(field: .splash, path: "/opt/homebrew/bin/splash"),
                RecentSelections.Entry(field: .huggingFaceModel, path: "a/b:Q4"),
            ]
        )
        config.huggingFaceModel = "not a model"
        XCTAssertEqual(
            RecentSelections.entries(in: config),
            [RecentSelections.Entry(field: .splash, path: "/opt/homebrew/bin/splash")],
            "a name that is no model ID is not remembered"
        )
    }

    func testLocalConfigurationsRememberTheFilesThatTakePart() {
        var config = ServerConfiguration.Config()
        config.splashPath = "/s"
        config.modelSource = .local
        config.modelPath = "/models/Qwen3.8-27B-UD-Q4_K_M.gguf"
        config.visionProjectorPath = "/mmproj.gguf"
        config.draftModel = "/draft"
        XCTAssertEqual(
            RecentSelections.entries(in: config),
            [
                .init(field: .splash, path: "/s"),
                .init(field: .model, path: "/models/Qwen3.8-27B-UD-Q4_K_M.gguf"),
                .init(field: .visionProjector, path: "/mmproj.gguf", family: "qwen3.8-27b"),
                .init(field: .draft, path: "/draft", family: "qwen3.8-27b"),
            ]
        )

        config.languageOnly = true
        config.draftModel = "owner/draft"
        XCTAssertEqual(
            RecentSelections.entries(in: config),
            [.init(field: .splash, path: "/s"), .init(field: .model, path: "/models/Qwen3.8-27B-UD-Q4_K_M.gguf")],
            "a text-only launch has no projector, and a repository is no path"
        )
    }

    // MARK: Families

    func testAProjectorIsRememberedPerFamily() {
        var recents = RecentSelections()
        recents.record("/a-mmproj.gguf", for: .visionProjector, family: "qwen3.8-27b")
        recents.record("/b-mmproj.gguf", for: .visionProjector, family: "qwen3.8-flash-next")
        XCTAssertEqual(recents.recentPaths(for: .visionProjector, family: "qwen3.8-27b"), ["/a-mmproj.gguf"])
        XCTAssertEqual(recents.recentPaths(for: .visionProjector, family: "qwen3.8-flash-next"), ["/b-mmproj.gguf"])
        XCTAssertEqual(recents.recentPaths(for: .visionProjector), [], "no family, no list")

        recents.clear(.visionProjector, family: "qwen3.8-27b")
        XCTAssertEqual(recents.recentPaths(for: .visionProjector, family: "qwen3.8-27b"), [])
        XCTAssertEqual(recents.recentPaths(for: .visionProjector, family: "qwen3.8-flash-next"), ["/b-mmproj.gguf"])
    }

    func testPruningReachesFamilyLists() throws {
        var recents = RecentSelections()
        recents.record("/gone.gguf", for: .visionProjector, family: "f")
        recents.record("/kept.gguf", for: .visionProjector, family: "f")
        recents.prune { _, path in path == "/gone.gguf" }
        XCTAssertEqual(recents.recentPaths(for: .visionProjector, family: "f"), ["/kept.gguf"])

        let decoded = try JSONDecoder().decode(RecentSelections.self, from: JSONEncoder().encode(recents))
        XCTAssertEqual(decoded.recentPaths(for: .visionProjector, family: "f"), ["/kept.gguf"])
    }

    func testAFamilyChangeDoesNotTreatTheOldFamilysFileAsReplaced() {
        let key: (RecentSelections.Field) -> (String) -> String = { _ in { $0 } }
        var recents = RecentSelections()
        recents.recordApply(
            from: [.init(field: .visionProjector, path: "/a.gguf", family: "a")],
            to: [.init(field: .visionProjector, path: "/b.gguf", family: "b")],
            fileKey: key
        )
        XCTAssertEqual(recents.recentPaths(for: .visionProjector, family: "b"), ["/b.gguf"])
        XCTAssertEqual(recents.recentPaths(for: .visionProjector, family: "a"), ["/a.gguf"])
    }

    func testApplyRecordsWhatChangedAndKeepsTheWayBack() {
        let key: (RecentSelections.Field) -> (String) -> String = { _ in { $0 } }
        var recents = RecentSelections()
        let before: [RecentSelections.Entry] = [.init(field: .model, path: "/old.gguf"), .init(field: .splash, path: "/s")]
        let after: [RecentSelections.Entry] = [.init(field: .model, path: "/new.gguf"), .init(field: .splash, path: "/s")]
        recents.recordApply(from: before, to: after, fileKey: key)

        XCTAssertEqual(recents.recentPaths(for: .model), ["/new.gguf", "/old.gguf"])
        XCTAssertEqual(recents.recentPaths(for: .splash), [], "an unchanged path is left alone")
    }

    func testApplyRecordsAPathThatLeftUseWithoutASuccessor() {
        let key: (RecentSelections.Field) -> (String) -> String = { _ in { $0 } }
        var recents = RecentSelections()
        recents.recordApply(
            from: [.init(field: .visionProjector, path: "/mmproj.gguf")],
            to: [],
            fileKey: key
        )
        XCTAssertEqual(recents.recentPaths(for: .visionProjector), ["/mmproj.gguf"])
    }
}
