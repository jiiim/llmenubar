// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest

@testable import llmenubar

final class ServerConfigurationTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        suiteNames = []
        super.tearDown()
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "llmenubar-config-tests-\(UUID().uuidString)"
        suiteNames.append(name)
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    func testANewInstallationNeedsSetup() throws {
        XCTAssertTrue(ServerConfiguration(defaults: try makeDefaults()).needsInitialSetup)
    }

    func testSetupWithAHubModelPersistsAndIsReloaded() throws {
        let defaults = try makeDefaults()
        let configuration = ServerConfiguration(defaults: defaults)
        configuration.completeInitialSetup(
            splashPath: "/opt/homebrew/bin/splash",
            model: .huggingFace("unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M")
        )

        let reloaded = ServerConfiguration(defaults: defaults)
        XCTAssertFalse(reloaded.needsInitialSetup)
        let config = reloaded.snapshot()
        XCTAssertEqual(config.splashPath, "/opt/homebrew/bin/splash")
        XCTAssertEqual(config.modelSource, .huggingFace)
        XCTAssertEqual(config.huggingFaceModel, "unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M")
    }

    func testSetupWithLocalFilesSelectsTheLocalSourceAndRemembersThePaths() throws {
        let defaults = try makeDefaults()
        let configuration = ServerConfiguration(defaults: defaults)
        configuration.completeInitialSetup(
            splashPath: "/opt/homebrew/bin/splash",
            model: .local("/models/m.gguf")
        )

        XCTAssertEqual(configuration.snapshot().modelSource, .local)
        XCTAssertEqual(configuration.snapshot().modelPath, "/models/m.gguf")
        XCTAssertEqual(configuration.recentSelections.recentPaths(for: .splash), ["/opt/homebrew/bin/splash"])
        XCTAssertEqual(configuration.recentSelections.recentPaths(for: .model), ["/models/m.gguf"])
    }

    func testApplyingRemembersTheModelAndTheFilesOfItsFamily() throws {
        let defaults = try makeDefaults()
        let configuration = ServerConfiguration(defaults: defaults)
        configuration.completeInitialSetup(splashPath: "/opt/homebrew/bin/splash", model: .huggingFace("a/b:Q4"))
        XCTAssertEqual(configuration.recentSelections.recentPaths(for: .huggingFaceModel), ["a/b:Q4"])

        // Real files: a remembered path whose file is gone is dropped.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-family-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projector = directory.appendingPathComponent("27b-mmproj.gguf").path
        let draft = directory.appendingPathComponent("27b-draft").path
        let model = directory.appendingPathComponent("Qwen3.8-27B-Q4_K_M.gguf").path
        for path in [projector, model] { FileManager.default.createFile(atPath: path, contents: Data()) }
        try FileManager.default.createDirectory(atPath: draft, withIntermediateDirectories: true)

        let previous = configuration.snapshot()
        var applied = previous
        applied.modelSource = .local
        applied.modelPath = model
        applied.visionProjectorPath = projector
        applied.draftModel = draft
        configuration.replace(with: applied)
        configuration.recordAppliedSelections(previous: previous)

        XCTAssertEqual(
            configuration.recentSelections.recentPaths(for: .visionProjector, family: "qwen3.8-27b"),
            [projector]
        )
        XCTAssertEqual(configuration.recentSelections.recentPaths(for: .visionProjector, family: "other"), [])
        XCTAssertEqual(configuration.recentSelections.recentPaths(for: .huggingFaceModel), ["a/b:Q4"], "a Hub ID is not pruned as a missing file")

        // A new draft of another family is offered that family's files, which are none yet.
        var other = applied
        other.modelPath = "/models/Qwen3.8-Flash-Next-Q4_K_XL.gguf"
        let restoration = try XCTUnwrap(configuration.familyRestoration(for: "qwen3.8-flash-next", current: other))
        XCTAssertEqual(restoration.visionProjector, "")
        // Back on the first family its files return.
        other.visionProjectorPath = ""
        other.draftModel = ""
        let back = try XCTUnwrap(configuration.familyRestoration(for: "qwen3.8-27b", current: other))
        XCTAssertEqual(back.visionProjector, projector)
        XCTAssertEqual(back.draft, draft)

        // And it all survives a relaunch.
        let reloaded = ServerConfiguration(defaults: defaults)
        XCTAssertEqual(
            reloaded.familyRestoration(for: "qwen3.8-27b", current: other)?.visionProjector,
            projector
        )
        XCTAssertEqual(reloaded.recentSelections.recentPaths(for: .huggingFaceModel), ["a/b:Q4"])
    }

    func testAConfigurationThatPredatesTheMemoryIsSeededFromItself() throws {
        let defaults = try makeDefaults()
        let first = ServerConfiguration(defaults: defaults)
        var config = ServerConfiguration.Config()
        config.splashPath = "/opt/homebrew/bin/splash"
        config.modelSource = .local
        config.modelPath = "/models/A-Q4_K_M.gguf"
        config.visionProjectorPath = "/models/a-mmproj.gguf"
        first.replace(with: config)
        first.save()
        defaults.removeObject(forKey: "llmenubar.modelFamilyMemory")

        let reloaded = ServerConfiguration(defaults: defaults)
        var other = config
        other.modelPath = "/models/B-Q4_K_M.gguf"
        other.visionProjectorPath = ""
        XCTAssertEqual(
            reloaded.familyRestoration(for: "a", current: other)?.visionProjector,
            "/models/a-mmproj.gguf"
        )
    }

    func testAnIncompleteConfigurationStillNeedsSetup() throws {
        let defaults = try makeDefaults()
        let configuration = ServerConfiguration(defaults: defaults)
        configuration.replace(with: ServerConfiguration.Config())
        configuration.save()
        XCTAssertTrue(ServerConfiguration(defaults: defaults).needsInitialSetup)
    }

    /// The log's size limit was once 1 to 10,240 MB; a saved value outside the
    /// present range is brought into it rather than left to fail validation.
    func testASavedLogSizeOutsideTheRangeIsClamped() throws {
        for (saved, expected) in [(1, 5), (5, 5), (64, 64), (128, 128), (10_240, 128)] {
            let defaults = try makeDefaults()
            defaults.set(Data("{\"logMaxSizeMB\":\(saved)}".utf8), forKey: "llmenubar.config")
            XCTAssertEqual(ServerConfiguration(defaults: defaults).snapshot().logMaxSizeMB, expected, "\(saved)")
        }
    }

    func testEveryActivationsChoiceIsSavedAndLoaded() throws {
        for choice in ServerConfiguration.Activations.allCases {
            var config = ServerConfiguration.Config()
            config.activations = choice
            let data = try JSONEncoder().encode(config)
            XCTAssertEqual(try JSONDecoder().decode(ServerConfiguration.Config.self, from: data).activations, choice)
        }
    }

    func testTheOptionsOfSplash174AreSavedAndLoaded() throws {
        var config = ServerConfiguration.Config()
        config.weights = .auto
        config.draftRevision = " v1 "
        config.shutdownTimeout = " 0 "
        let normalized = config.normalized()
        XCTAssertEqual(normalized.draftRevision, "v1")
        XCTAssertEqual(normalized.shutdownTimeout, "0")
        let long = String(repeating: "0", count: 40)
        for (typed, stored) in [("00", "0"), (long, "0"), ("05", "5"), (long + "15", "15"), ("15", "15"), ("", ""), ("2.5", "2.5")] {
            config.shutdownTimeout = typed
            XCTAssertEqual(config.normalized().shutdownTimeout, stored, typed)
        }
        for (typed, stored) in [("00", "0"), (long, "0"), ("007G", "007G"), ("auto", "auto")] {
            config.maxCacheDisk = typed
            config.maxCacheDiskWrites = typed
            XCTAssertEqual(config.normalized().maxCacheDisk, stored, typed)
            XCTAssertEqual(config.normalized().maxCacheDiskWrites, stored, typed)
        }
        let decoded = try JSONDecoder().decode(ServerConfiguration.Config.self, from: JSONEncoder().encode(normalized))
        XCTAssertEqual(decoded, normalized)
    }

    func testMissingAndUnreadableKeysFallBackToDefaults() throws {
        let defaults = try makeDefaults()
        let stored = """
        {"splashPath":"/opt/homebrew/bin/splash","huggingFaceModel":"a/b","port":"not a number",
         "kvFormat":"from-the-future","maxContext":"1M","newKeyFromALaterBuild":true}
        """
        defaults.set(Data(stored.utf8), forKey: "llmenubar.config")

        let config = ServerConfiguration(defaults: defaults).snapshot()
        XCTAssertEqual(config.splashPath, "/opt/homebrew/bin/splash")
        XCTAssertEqual(config.huggingFaceModel, "a/b")
        XCTAssertEqual(config.maxContext, "1M")
        XCTAssertEqual(config.port, 8_000, "a value of the wrong type falls back")
        XCTAssertEqual(config.kvFormat, .standard, "an unknown choice falls back")
        XCTAssertEqual(config.activations, .standard, "a saved configuration without the option reads as default")
        XCTAssertEqual(config.cachedStates, .standard, "a saved configuration without the option reads as default")
        XCTAssertEqual(config.maxConcurrentRequests, "", "a saved configuration without the option reads as default")
        XCTAssertFalse(config.hasSamplingDefaults)
        XCTAssertFalse(config.recalibrateANE)
        XCTAssertEqual(config.reasoningScope, .requestsWithoutOne, "a saved configuration without the option keeps its effort as the default")
        XCTAssertEqual(config.host, "127.0.0.1")
        XCTAssertTrue(config.chatPageEnabled)
    }

    func testNormalizationTrimsTextAndStoresPathsInOneForm() {
        var config = ServerConfiguration.Config()
        // A path that does not exist, so no symlink on this Mac changes it.
        config.splashPath = "  /opt/llmenubar-test/bin/../bin/splash  "
        config.huggingFaceModel = " a/b "
        config.modelPath = "/models//m.gguf"
        config.host = " 0.0.0.0 "
        config.maxMemory = " 28G "
        config.draftModel = "  owner/draft "
        config.logPath = "~/Library/Logs/llmenubar/./splash.log"

        let normalized = config.normalized()
        XCTAssertEqual(normalized.splashPath, "/opt/llmenubar-test/bin/splash")
        XCTAssertEqual(normalized.huggingFaceModel, "a/b")
        XCTAssertEqual(normalized.modelPath, "/models/m.gguf")
        XCTAssertEqual(normalized.host, "0.0.0.0")
        XCTAssertEqual(normalized.maxMemory, "28G")
        XCTAssertEqual(normalized.draftModel, "owner/draft")
        // A `~` path is stored absolute, so it means the same thing wherever
        // the app is started from.
        XCTAssertEqual(normalized.logPath, NSHomeDirectory() + "/Library/Logs/llmenubar/splash.log")
        XCTAssertEqual(normalized.normalized(), normalized)
    }

    func testTheNewTextSettingsAreNormalized() {
        var config = ServerConfiguration.Config()
        config.apiKey = "  llm-key \n"
        config.localModelName = " local/mine "
        config.environment = "  A=1  \n\n\r\n B=2 \n"
        let normalized = config.normalized()
        XCTAssertEqual(normalized.apiKey, "llm-key")
        XCTAssertEqual(normalized.localModelName, "local/mine")
        XCTAssertEqual(normalized.environment, "A=1\nB=2")
        XCTAssertEqual(normalized.normalized(), normalized)
    }

    func testTheKeyAndEnvironmentSurviveARestart() throws {
        let defaults = try makeDefaults()
        let secrets = MemorySecretStore()
        let configuration = ServerConfiguration(defaults: defaults, secrets: secrets)
        var config = ServerConfiguration.Config()
        config.apiKey = "llm-key"
        config.environment = "SPLASH_CRASH_TRACE=1"
        config.localModelName = "local/mine"
        config.splashPath = "/opt/homebrew/bin/splash"
        config.huggingFaceModel = "a/b"
        configuration.replace(with: config)
        configuration.save()

        let reloaded = ServerConfiguration(defaults: defaults, secrets: secrets).snapshot()
        XCTAssertEqual(reloaded.apiKey, "llm-key")
        XCTAssertEqual(reloaded.environment, "SPLASH_CRASH_TRACE=1")
        XCTAssertEqual(reloaded.localModelName, "local/mine")
    }

    func testAFolderDraftIsStoredAsAPathAndARepositoryAsText() {
        var config = ServerConfiguration.Config()
        config.draftModel = "/models//draft/"
        XCTAssertEqual(config.normalized().draftModel, "/models/draft")
        config.draftModel = "owner/draft"
        XCTAssertEqual(config.normalized().draftModel, "owner/draft")
    }

    func testAppPreferencesDefaultAndPersist() throws {
        let defaults = try makeDefaults()
        let configuration = ServerConfiguration(defaults: defaults)
        XCTAssertTrue(configuration.confirmQuitWhileServerActive)
        XCTAssertTrue(configuration.autoRestartServer)
        XCTAssertFalse(configuration.keepsAwakeWhileRunning)
        XCTAssertFalse(configuration.showsPerformanceInMenuBar)

        configuration.setConfirmQuitWhileServerActive(false)
        configuration.setAutoRestartServer(false)
        configuration.setKeepsAwakeWhileRunning(true)
        configuration.setShowsPerformanceInMenuBar(true)

        let reloaded = ServerConfiguration(defaults: defaults)
        XCTAssertFalse(reloaded.confirmQuitWhileServerActive)
        XCTAssertFalse(reloaded.autoRestartServer)
        XCTAssertTrue(reloaded.keepsAwakeWhileRunning)
        XCTAssertTrue(reloaded.showsPerformanceInMenuBar)
    }

    func testTheStoredKeysBelongToThisApp() throws {
        let defaults = try makeDefaults()
        ServerConfiguration(defaults: defaults).completeInitialSetup(
            splashPath: "/opt/homebrew/bin/splash",
            model: .huggingFace("a/b")
        )
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.contains("config") || $0.contains("llmenubar") }
        XCTAssertTrue(keys.contains("llmenubar.config"))
        XCTAssertFalse(keys.contains { $0.contains("dsmenubar") })
    }

    func testTheCachedStatesDefaultIsNotCalledEightBitOnAnEngineWithoutTheOption() {
        XCTAssertEqual(ServerConfiguration.CachedStates.standard.title(engineHasOption: true), "Engine default (8-bit)")
        XCTAssertEqual(ServerConfiguration.CachedStates.standard.title(engineHasOption: false), "Engine default (as Recurrent state)")
        XCTAssertEqual(ServerConfiguration.CachedStates.exact.title(engineHasOption: false), "Exact")
    }
}
