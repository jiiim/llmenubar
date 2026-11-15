// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest

@testable import llmenubar

/// Applying a Settings draft: what is checked, what is committed, what is
/// remembered, and what the status menu says about the model afterwards.
@MainActor
final class ServerManagerApplyTests: XCTestCase {
    private var splashPath = ""

    private func makeManager() throws -> ServerManager {
        let suiteName = "llmenubar-apply-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        splashPath = try existingSplash()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return ServerManager(config: ServerConfiguration(defaults: defaults))
    }

    /// A file that exists, so the history keeps it: entries whose file is gone
    /// from a mounted volume are dropped when a configuration is applied.
    private func existingSplash() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-splash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("splash")
        try Data("#!/bin/sh\n".utf8).write(to: url)
        return url.path
    }

    private func valid(_ manager: ServerManager) -> ServerConfiguration.Config {
        var config = manager.configurationSnapshot()
        config.splashPath = splashPath
        config.huggingFaceModel = "owner/repo:Q4"
        return config
    }

    func testAValidDraftIsCommittedAndRemembered() throws {
        let manager = try makeManager()
        let previous = manager.configurationSnapshot()
        var draft = valid(manager)
        draft.maxContext = "128K"

        let result = manager.applyConfiguration(draft, derived: .uninspected, previous: previous)

        XCTAssertEqual(result.kind, .applied)
        XCTAssertEqual(manager.configurationSnapshot().maxContext, "128K")
        XCTAssertEqual(manager.recentSelections.recentPaths(for: .splash), [splashPath])
        XCTAssertEqual(manager.activeModelInfo.title, "owner/repo:Q4")
        XCTAssertEqual(manager.activeModelInfo.subtitle, "Hugging Face")
    }

    func testAnInvalidDraftChangesNothing() throws {
        let manager = try makeManager()
        let previous = manager.configurationSnapshot()
        var draft = valid(manager)
        draft.port = 80

        let result = manager.applyConfiguration(draft, derived: .uninspected, previous: previous)

        XCTAssertEqual(result.kind, .invalid)
        XCTAssertEqual(manager.configurationSnapshot(), previous)
        XCTAssertEqual(manager.recentSelections, RecentSelections())
    }

    func testAFileProblemFoundWhileCheckingRefusesTheDraft() throws {
        let manager = try makeManager()
        let previous = manager.configurationSnapshot()
        var derived = SplashDerivedState()
        derived.splashIssue = "Choose splash, not another executable."

        let result = manager.applyConfiguration(valid(manager), derived: derived, previous: previous)
        XCTAssertEqual(result.kind, .invalid)
    }

    func testADraftMadeAgainstAnOlderConfigurationIsRefused() throws {
        let manager = try makeManager()
        let stale = manager.configurationSnapshot()
        var moved = valid(manager)
        moved.maxContext = "1M"
        XCTAssertEqual(manager.applyConfiguration(moved, derived: .uninspected, previous: stale).kind, .applied)

        var draft = valid(manager)
        draft.maxContext = "64K"
        XCTAssertEqual(
            manager.applyConfiguration(draft, derived: .uninspected, previous: stale).kind,
            .invalid,
            "the configuration changed after this draft was made"
        )
        XCTAssertEqual(manager.configurationSnapshot().maxContext, "1M")
    }

    func testSwitchingToLocalFilesRecordsThemAndNamesThemInTheMenu() throws {
        let manager = try makeManager()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-apply-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let model = directory.appendingPathComponent("Qwen.gguf")
        try Data("GGUF....".utf8).write(to: model)

        var draft = valid(manager)
        draft.modelSource = .local
        draft.modelPath = model.path
        XCTAssertEqual(
            manager.applyConfiguration(
                draft, derived: .uninspected, previous: manager.configurationSnapshot()
            ).kind,
            .applied
        )

        XCTAssertEqual(manager.recentSelections.recentPaths(for: .model), [model.path])
        XCTAssertEqual(manager.activeModelInfo.title, "Qwen.gguf")
        XCTAssertEqual(manager.activeModelInfo.names, ["local/Qwen"])
        XCTAssertEqual(manager.activeModelInfo.subtitle, "On this Mac")

        try FileManager.default.removeItem(at: model)
        manager.refreshActiveModelInfo()
        XCTAssertEqual(manager.activeModelInfo.subtitle, "Not found")
    }

    func testTheModelRowIsHiddenUntilAModelIsChosen() throws {
        let manager = try makeManager()
        manager.refreshActiveModelInfo()
        XCTAssertEqual(manager.activeModelInfo, .empty)
    }
}
