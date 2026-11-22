// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest

@testable import llmenubar

final class ConfigurationValidationTests: XCTestCase {
    private typealias Config = ServerConfiguration.Config

    private func valid() -> Config {
        var config = Config()
        config.splashPath = "/opt/homebrew/bin/splash"
        config.huggingFaceModel = "unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M"
        return config
    }

    private let splash = SplashBuild(
        identity: .splash(version: "1.5.0"),
        serveFlags: ["--model", "--port", "--host", "--mmproj", "--draft-model"]
    )

    func testADefaultedConfigurationWithASplashAndAModelIsValid() {
        XCTAssertEqual(valid().validationErrors(), [:])
        XCTAssertNil(valid().firstValidationError())
    }

    func testAFreshConfigurationNeedsASplashAndAModel() {
        let errors = Config().validationErrors()
        XCTAssertNotNil(errors[.splashPath])
        XCTAssertNotNil(errors[.huggingFaceModel])
    }

    func testSplashPathMustBeAbsoluteAndUsable() {
        var config = valid()
        config.splashPath = "bin/splash"
        XCTAssertNotNil(config.validationErrors()[.splashPath])

        config.splashPath = "~/bin/splash"
        XCTAssertNil(config.validationErrors()[.splashPath])

        var derived = SplashDerivedState()
        derived.splashIssue = "Choose splash, not another executable."
        XCTAssertEqual(valid().validationErrors(derived: derived)[.splashPath], derived.splashIssue)
    }

    func testHuggingFaceModelIDsAreChecked() {
        var config = valid()
        config.huggingFaceModel = "not a model"
        XCTAssertNotNil(config.validationErrors()[.huggingFaceModel])
        config.huggingFaceModel = "owner/repo"
        XCTAssertNil(config.validationErrors()[.huggingFaceModel])
    }

    func testLocalModelsNeedAPathAndTheirFilesMustBeUsable() {
        var config = valid()
        config.modelSource = .local
        XCTAssertNotNil(config.validationErrors()[.modelPath])

        config.modelPath = "/models/m.gguf"
        XCTAssertNil(config.validationErrors()[.modelPath])

        var derived = SplashDerivedState()
        derived.modelIssue = .missing
        XCTAssertEqual(config.validationErrors(derived: derived)[.modelPath], SplashModel.LocalModelIssue.missing.message)
        // The hub field is not the local model's business.
        XCTAssertNil(config.validationErrors(derived: derived)[.huggingFaceModel])
    }

    func testTheProjectorIsCheckedOnlyWhereItIsUsed() {
        var derived = SplashDerivedState()
        derived.visionProjectorIssue = "That file is not a GGUF."

        var config = valid()
        config.modelSource = .local
        config.modelPath = "/models/m.gguf"
        config.visionProjectorPath = "/models/mmproj.gguf"
        XCTAssertNotNil(config.validationErrors(derived: derived)[.visionProjectorPath])

        config.languageOnly = true
        XCTAssertNil(config.validationErrors(derived: derived)[.visionProjectorPath])

        config.languageOnly = false
        config.modelSource = .huggingFace
        XCTAssertNil(config.validationErrors(derived: derived)[.visionProjectorPath])
    }

    func testTheDraftIsARepositoryForHubModelsAndAFolderForLocalFiles() {
        var config = valid()
        config.draftModel = "owner/draft"
        XCTAssertNil(config.validationErrors()[.draftModel])
        config.draftModel = "/models/draft"
        XCTAssertNotNil(config.validationErrors()[.draftModel])

        config.modelSource = .local
        config.modelPath = "/models/m.gguf"
        config.draftModel = "/models/draft"
        XCTAssertNil(config.validationErrors()[.draftModel])
        config.draftModel = "owner/draft"
        XCTAssertNotNil(config.validationErrors()[.draftModel])
    }

    func testARevisionBelongsToAHubModel() {
        var config = valid()
        config.revision = "main"
        XCTAssertNil(config.validationErrors()[.revision])
        config.revision = "bad rev"
        XCTAssertNotNil(config.validationErrors()[.revision])
        config.revision = "main"
        config.modelSource = .local
        config.modelPath = "/models/m.gguf"
        XCTAssertNotNil(config.validationErrors()[.revision])
    }

    func testNetworkFields() {
        var config = valid()
        config.host = ""
        XCTAssertNotNil(config.validationErrors()[.host])
        config.host = "127.0.0.1 "
        XCTAssertNil(config.normalized().validationErrors()[.host])
        config.host = "a b"
        XCTAssertNotNil(config.validationErrors()[.host])
        for bad in ["foo/bar", "localhost:8000", "fe80::1%en0", "[]", "::1", "[::1]", "::"] {
            config.host = bad
            XCTAssertNotNil(config.normalized().validationErrors()[.host], bad)
        }
        for good in ["127.0.0.1", "0.0.0.0", "localhost", "mymac.local"] {
            config.host = good
            XCTAssertNil(config.normalized().validationErrors()[.host], good)
        }
        config.host = "localhost:8000"
        XCTAssertEqual(config.normalized().validationErrors()[.host],
                       "Enter the address without a port. The port is set below.")

        config = valid()
        for port in [0, 80, 1_023, 65_536, -1] {
            config.port = port
            XCTAssertNotNil(config.validationErrors()[.port], "\(port)")
        }
        for port in [1_024, 8_000, 65_535] {
            config.port = port
            XCTAssertNil(config.validationErrors()[.port], "\(port)")
        }

        config.allowedOrigins = "https://a.example, nope"
        XCTAssertNotNil(config.validationErrors()[.allowedOrigins])
        config.allowedOrigins = "https://a.example, *"
        XCTAssertNil(config.validationErrors()[.allowedOrigins])
    }

    func testValuesSplashWouldReadAsOptionsOrRefuse() {
        var config = ServerConfiguration.Config()
        config.allowedHosts = "mymac.local, -evil"
        XCTAssertNotNil(config.validationErrors()[.allowedHosts])
        for bad in ["mymac.local:8000", "a/b", "a b"] {
            config.allowedHosts = bad
            XCTAssertNotNil(config.validationErrors()[.allowedHosts], bad)
        }
        config.allowedHosts = "mymac.local, 192.168.1.5, other.example"
        XCTAssertNil(config.validationErrors()[.allowedHosts])
        config.servedModelNames = "-gpt"
        XCTAssertNotNil(config.validationErrors()[.servedModelNames])
        config.thinkingEndText = "-- now the answer. </think>"
        XCTAssertNotNil(config.validationErrors()[.thinkingEndText])
        config.thinkingEndText = "Now the answer. </think>"
        XCTAssertNil(config.validationErrors()[.thinkingEndText])
    }

    func testBlankOptionsAreValidAndBadOnesAreNamed() {
        var config = valid()
        config.maxMemory = "28G"
        config.maxContext = "1M"
        config.pleMemory = "off"
        config.expertMemory = "auto"
        config.sparseKVMemory = "1200M"
        config.idleRelease = "off"
        config.maxCacheDisk = "0"
        config.maxCacheDiskWrites = "0"
        config.servedModelNames = "gpt-4o, claude"
        config.thinkingTokenBudget = "0"
        config.maxRequestSize = "128M"
        config.maxImagePixels = "65536"
        config.requestTimeout = "1h"
        config.queueSize = "1"
        config.decodeShare = "0"
        XCTAssertEqual(config.validationErrors(), [:])

        config.maxMemory = "lots"
        config.maxContext = "2M"
        config.pleMemory = "some"
        config.expertMemory = "0"
        config.sparseKVMemory = "off"
        config.idleRelease = "never"
        config.maxCacheDisk = "-1"
        config.maxCacheDiskWrites = "auto"
        config.servedModelNames = "good, bad name"
        config.thinkingTokenBudget = "-1"
        config.maxRequestSize = "auto"
        config.maxImagePixels = "100"
        config.requestTimeout = "0"
        config.queueSize = "0"
        config.decodeShare = "-1"
        let errors = config.validationErrors()
        for field in [
            Config.Field.maxMemory, .maxContext, .pleMemory, .expertMemory, .sparseKVMemory, .idleRelease,
            .maxCacheDisk, .maxCacheDiskWrites, .servedModelNames, .thinkingTokenBudget, .maxRequestSize,
            .maxImagePixels, .requestTimeout, .queueSize, .decodeShare,
        ] {
            XCTAssertNotNil(errors[field], field.rawValue)
        }
    }

    func testTheAPIKeyTakesVisibleASCIIOnly() {
        var config = valid()
        config.apiKey = "llm-0123456789abcdef"
        XCTAssertNil(config.validationErrors()[.apiKey])
        for key in ["has space", "tab\tkey", "naïve", "emoji🔑"] {
            config.apiKey = key
            XCTAssertNotNil(config.validationErrors()[.apiKey], key)
        }
    }

    func testTheLocalNameIsAModelID() {
        var config = valid()
        config.modelSource = .local
        config.modelPath = "/models/m.gguf"
        config.localModelName = "local/huihui-v2-q4"
        XCTAssertNil(config.validationErrors()[.localModelName])
        config.localModelName = "huihui"
        XCTAssertNotNil(config.validationErrors()[.localModelName])
        config.localModelName = "local/has space"
        XCTAssertNotNil(config.validationErrors()[.localModelName])
        // A name set for local files is not the Hugging Face model's concern.
        config.modelSource = .huggingFace
        XCTAssertNil(config.validationErrors()[.localModelName])
    }

    func testTheEnvironmentIsCheckedLineByLine() {
        var config = valid()
        config.environment = "SPLASH_CRASH_TRACE=1\n# comment\nA_B2=x y"
        XCTAssertNil(config.validationErrors()[.environment])
        for text in ["NOEQUALS", "1BAD=x", "BAD-NAME=x", "=x", "SPLASH_API_KEY=abc"] {
            config.environment = text
            XCTAssertNotNil(config.validationErrors()[.environment], text)
        }
    }

    func testTheLogPathAndSizeAreChecked() {
        var config = valid()
        config.logPath = "relative/splash.log"
        XCTAssertNotNil(config.validationErrors()[.logPath])
        config = valid()
        config.logMaxSizeMB = 4
        XCTAssertNotNil(config.validationErrors()[.logMaxSizeMB])
        config.logMaxSizeMB = 129
        XCTAssertNotNil(config.validationErrors()[.logMaxSizeMB])
        config.logMaxSizeMB = 5
        XCTAssertNil(config.validationErrors()[.logMaxSizeMB])
        config.logMaxSizeMB = 128
        XCTAssertNil(config.validationErrors()[.logMaxSizeMB])
    }

    // MARK: Options this Splash does not take

    func testAnOptionTheBuildLacksIsRefusedOnlyWhenSet() {
        var derived = SplashDerivedState()
        derived.build = SplashBuild(identity: .splash(version: "1.2.0"), serveFlags: ["--model", "--port", "--host"])

        var config = valid()
        XCTAssertEqual(config.validationErrors(derived: derived), [:], "defaults need no option the build lacks")

        config.queueSize = "8"
        config.expertMemory = "16G"
        let errors = config.validationErrors(derived: derived)
        XCTAssertTrue(errors[.queueSize]?.contains("--queue-size") == true)
        XCTAssertTrue(errors[.expertMemory]?.contains("--expert-memory") == true)
        XCTAssertNil(errors[.maxMemory])
    }

    func testActivationsNeedABuildThatTakesThem() {
        var derived = SplashDerivedState()
        derived.build = SplashBuild(identity: .splash(version: "1.5.0"), serveFlags: ["--model", "--port", "--host"])
        var config = valid()
        XCTAssertEqual(config.validationErrors(derived: derived), [:], "the default needs no option")

        config.activations = .bf16
        XCTAssertTrue(config.validationErrors(derived: derived)[.activations]?.contains("--activations") == true)
        XCTAssertEqual(SettingsPane.containing(.activations), .memory)

        derived.build = SplashBuild(identity: .splash(version: "1.6.1"), serveFlags: ["--model", "--port", "--host", "--activations"])
        XCTAssertEqual(config.validationErrors(derived: derived), [:])
    }

    func testCachedStatesNeedABuildThatTakesThem() {
        var derived = SplashDerivedState()
        derived.build = SplashBuild(identity: .splash(version: "1.6.1"), serveFlags: ["--model", "--port", "--host"])
        var config = valid()
        XCTAssertEqual(config.validationErrors(derived: derived), [:], "the default needs no option")

        config.cachedStates = .exact
        XCTAssertTrue(config.validationErrors(derived: derived)[.cachedStates]?.contains("--cached-states") == true)
        XCTAssertEqual(SettingsPane.containing(.cachedStates), .memory)

        derived.build = SplashBuild(identity: .splash(version: "1.7.0"), serveFlags: ["--model", "--port", "--host", "--cached-states"])
        XCTAssertEqual(config.validationErrors(derived: derived), [:])
    }

    func testTheOptionsOfSplash171NeedABuildThatTakesThem() {
        var derived = SplashDerivedState()
        derived.build = SplashBuild(identity: .splash(version: "1.7.0"), serveFlags: ["--model", "--port", "--host"])
        var config = valid()
        XCTAssertEqual(config.validationErrors(derived: derived), [:], "the defaults need no option")

        config.maxConcurrentRequests = "8"
        config.applySampling("temperature=0.7")
        config.recalibrateANE = true
        let errors = config.validationErrors(derived: derived)
        XCTAssertTrue(errors[.maxConcurrentRequests]?.contains("--max-concurrent-requests") == true)
        XCTAssertTrue(errors[.samplingTemperature]?.contains("--sampling-default") == true)
        XCTAssertTrue(errors[.recalibrateANE]?.contains("--recalibrate-ane") == true)
        XCTAssertEqual(SettingsPane.containing(.maxConcurrentRequests), .requests)
        for parameter in Config.samplingParameters {
            XCTAssertEqual(SettingsPane.containing(parameter.field), .requests)
        }
        XCTAssertEqual(SettingsPane.containing(.recalibrateANE), .memory)

        derived.build = SplashBuild(
            identity: .splash(version: "1.7.1"),
            serveFlags: ["--model", "--port", "--host", "--max-concurrent-requests", "--sampling-default", "--recalibrate-ane"]
        )
        XCTAssertEqual(config.validationErrors(derived: derived), [:])
    }

    func testConcurrentRequestsTakeOneToEight() {
        var config = valid()
        for good in ["1", "4", "8", "+3", "03", "４", " 5 "] {
            config.maxConcurrentRequests = good
            XCTAssertNil(config.validationErrors()[.maxConcurrentRequests], good)
        }
        for bad in ["0", "9", "x", "2.5", "-1", "3_0", "1e0"] {
            config.maxConcurrentRequests = bad
            XCTAssertNotNil(config.validationErrors()[.maxConcurrentRequests], bad)
        }
    }

    func testSamplingDefaultsFollowTheRangesSplashChecks() {
        var config = valid()
        let good = [
            "temperature=0", "temperature=2", "top_p=1", "top_p=0.01", "top_k=0", "top_k=-1", "top_k=40",
            "min_p=0", "min_p=1", "presence_penalty=-2", "frequency_penalty=2", "repetition_penalty=1.1",
            "temperature = 0.7, top_p=0.9", "temperature=",
            "temperature=1e0", "temperature=1E-1", "temperature=.5", "temperature=1.", "temperature=+1",
            "temperature=1_0e-1", "temperature=1e-400", "top_k=+5", "top_k=1_0", "top_k=-0", "top_k=-01",
            "top_k=99999999999999999999", "top_p=1.5e-45", "repetition_penalty=3.4e38", "temperature=１",
        ]
        for text in good {
            config = valid()
            config.applySampling(text)
            XCTAssertTrue(Config.samplingParameters.allSatisfy { config.validationErrors()[$0.field] == nil }, text)
        }
        let bad = [
            "temperature=abc", "temperature=-1", "temperature=2.1",
            "top_p=0", "top_p=2", "top_k=1.5", "min_p=1.5", "presence_penalty=3", "frequency_penalty=-2.5",
            "repetition_penalty=0", "temperature=nan", "temperature=inf", "temperature=0x1", "temperature=1__0",
            "temperature=_1", "temperature=1_", "temperature=1e", "temperature=e1", "temperature=.",
            "top_k=-2", "top_k=-99999999999999999999", "top_k=5.0", "top_k=1e1", "top_p=1e-45", "top_p=5e-324",
            "repetition_penalty=3.5e38", "repetition_penalty=1e-45", "temperature=1e999",
        ]
        for text in bad {
            config = valid()
            config.applySampling(text)
            XCTAssertFalse(Config.samplingParameters.allSatisfy { config.validationErrors()[$0.field] == nil }, text)
        }
        config = valid()
        config.applySampling("repetition_penalty=3.5e38")
        XCTAssertTrue(config.validationErrors()[.samplingRepetitionPenalty]?.contains("3.4028235e38") == true)
        config = valid()
        config.applySampling("top_k=-2")
        XCTAssertEqual(config.validationErrors()[.samplingTopK], "Use a whole number, -1 or more.")
    }

    func testBlankSamplingValuesAreNotPassed() {
        var config = valid()
        XCTAssertFalse(config.hasSamplingDefaults)
        XCTAssertEqual(config.samplingArguments, [])
        config.applySampling("top_k=40, temperature=0.7")
        XCTAssertTrue(config.hasSamplingDefaults)
        XCTAssertEqual(config.samplingArguments, ["temperature=0.7", "top_k=40"], "in Splash's order")
    }

    func testRecalibratingNeedsTheNeuralEngineOn() {
        var config = valid()
        config.recalibrateANE = true
        XCTAssertNil(config.validationErrors()[.recalibrateANE])
        config.disableANE = true
        XCTAssertNotNil(config.validationErrors()[.recalibrateANE])
    }

    func testAnEffortForEveryRequestNeedsABuildThatTakesIt() {
        var derived = SplashDerivedState()
        derived.build = SplashBuild(identity: .splash(version: "1.6.1"), serveFlags: ["--model", "--port", "--host", "--default-reasoning-effort"])
        var config = valid()
        config.reasoningEffort = .low
        XCTAssertEqual(config.validationErrors(derived: derived), [:], "an effort for requests that set none is old")

        config.reasoningScope = .everyRequest
        XCTAssertTrue(config.validationErrors(derived: derived)[.reasoningEffort]?.contains("--reasoning-effort") == true)
        XCTAssertEqual(SettingsPane.containing(.reasoningEffort), .requests)

        config.reasoningEffort = .modelDefault
        XCTAssertEqual(config.validationErrors(derived: derived), [:], "no effort, no option")

        derived.build = SplashBuild(identity: .splash(version: "1.7.0"), serveFlags: ["--model", "--port", "--host", "--reasoning-effort"])
        config.reasoningEffort = .low
        XCTAssertEqual(config.validationErrors(derived: derived), [:])
    }

    func testAChatTemplateMustBeAFileThatCanBeRead() throws {
        var config = valid()
        config.chatTemplatePath = "relative.jinja"
        XCTAssertNotNil(config.validationErrors()[.chatTemplatePath], "a relative path is not what the Choose button stores")
        XCTAssertEqual(SettingsPane.containing(.chatTemplatePath), .model)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-template-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("chat.jinja")

        config.chatTemplatePath = file.path
        XCTAssertNotNil(SplashDerivedState.compute(for: config).chatTemplateIssue, "a file that is not there")
        try Data("{{ messages }}".utf8).write(to: file)
        XCTAssertNil(SplashDerivedState.compute(for: config).chatTemplateIssue)

        var derived = SplashDerivedState()
        derived.chatTemplateIssue = "Choose a readable chat template file."
        XCTAssertNotNil(config.validationErrors(derived: derived)[.chatTemplatePath])

        derived = SplashDerivedState()
        derived.build = SplashBuild(identity: .splash(version: "1.6.1"), serveFlags: ["--model", "--port", "--host"])
        XCTAssertTrue(config.validationErrors(derived: derived)[.chatTemplatePath]?.contains("--chat-template-file") == true)
    }

    func testASocketHostIsCheckedAsAPathAndNeedsASplashThatTakesIt() throws {
        // Short, because a socket path holds at most 103 bytes and the
        // temporary directory's own name is longer than that.
        let folder = URL(fileURLWithPath: "/tmp/llmb-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var config = valid()
        config.host = "unix:" + folder.appendingPathComponent("s.sock").path
        XCTAssertNil(config.validationErrors()[.host], "an uninspected build is given the benefit of the doubt")

        config.host = "unix:"
        XCTAssertNotNil(config.validationErrors()[.host])
        config.host = "unix:relative.sock"
        XCTAssertNotNil(config.validationErrors()[.host])
        config.host = "unix:/no/such/folder/s.sock"
        XCTAssertTrue(config.validationErrors()[.host]?.contains("folder") == true)

        config.host = "unix:" + folder.appendingPathComponent("a b.sock").path
        XCTAssertNil(config.validationErrors()[.host], "spaces are fine in a path")

        var derived = SplashDerivedState()
        derived.build = SplashBuild(identity: .splash(version: "1.6.1"), serveFlags: ["--model", "--port", "--host", "--default-reasoning-effort"])
        XCTAssertTrue(config.validationErrors(derived: derived)[.host]?.contains("1.7.0") == true)

        derived.build = SplashBuild(identity: .splash(version: "1.7.0"), serveFlags: ["--model", "--port", "--host", "--reasoning-effort"])
        XCTAssertNil(config.validationErrors(derived: derived)[.host])
    }

    func testAnUninspectedBuildIsGivenTheBenefitOfTheDoubt() {
        var config = valid()
        config.queueSize = "8"
        XCTAssertEqual(config.validationErrors(derived: .uninspected), [:])

        // So is a Splash whose help could not be read.
        var derived = SplashDerivedState()
        derived.build = SplashBuild(identity: .splash(version: "1.5.0"), serveFlags: [])
        XCTAssertEqual(config.validationErrors(derived: derived), [:])
    }

    func testAProjectorTheBuildLacksIsRefusedForLocalFiles() {
        var derived = SplashDerivedState()
        derived.build = SplashBuild(identity: .splash(version: "1.4.0"), serveFlags: ["--model", "--model-dir"])
        var config = valid()
        config.modelSource = .local
        config.modelPath = "/models/m.gguf"
        config.visionProjectorPath = "/models/mmproj.gguf"
        XCTAssertTrue(config.validationErrors(derived: derived)[.visionProjectorPath]?.contains("--mmproj") == true)
    }

    // MARK: Errors and panes

    func testTheFirstErrorFollowsTheFieldOrderALaunchMeetsThem() {
        var config = Config()
        config.port = 80
        XCTAssertEqual(config.firstValidationError(), "Choose the splash executable.")
    }

    func testEveryFieldHasAPane() {
        for field in Config.Field.allCases {
            _ = SettingsPane.containing(field)
        }
        XCTAssertEqual(SettingsPane.containing(.splashPath), .general)
        XCTAssertEqual(SettingsPane.containing(.visionProjectorPath), .model)
        XCTAssertEqual(SettingsPane.containing(.port), .server)
        XCTAssertEqual(SettingsPane.containing(.maxContext), .memory)
        XCTAssertEqual(SettingsPane.containing(.cacheDirectory), .cache)
        XCTAssertEqual(SettingsPane.containing(.queueSize), .requests)
        XCTAssertEqual(SettingsPane.containing(.apiKey), .api)
        XCTAssertEqual(SettingsPane.containing(.localModelName), .api)
        XCTAssertEqual(SettingsPane.containing(.logMaxSizeMB), .diagnostics)
    }

    func testRestoringDefaultsKeepsTheInstallationAndModel() {
        var config = valid()
        config.maxContext = "1M"
        config.port = 9_000
        config.logPath = "/tmp/x.log"
        config.logMaxSizeMB = 3
        config.modelSource = .local
        config.modelPath = "/models/m.gguf"
        config.launchAtLogin = true
        config.localModelName = "local/mine"
        config.environment = "SPLASH_CRASH_TRACE=1"
        config.apiKey = "llm-key"

        let restored = config.restoringDefaults()
        XCTAssertEqual(restored.localModelName, "local/mine")
        XCTAssertEqual(restored.environment, "SPLASH_CRASH_TRACE=1")
        XCTAssertEqual(restored.apiKey, "", "the key is a Server option and goes with the rest")
        XCTAssertEqual(restored.splashPath, config.splashPath)
        XCTAssertEqual(restored.modelSource, .local)
        XCTAssertEqual(restored.modelPath, "/models/m.gguf")
        XCTAssertEqual(restored.logPath, "/tmp/x.log")
        XCTAssertEqual(restored.logMaxSizeMB, 3)
        XCTAssertTrue(restored.launchAtLogin)
        XCTAssertEqual(restored.maxContext, "")
        XCTAssertEqual(restored.port, 8_000)
    }
}

extension ServerConfiguration.Config {
    /// Sets the sampling values from `name=value` items separated by commas.
    mutating func applySampling(_ text: String) {
        for item in text.split(separator: ",") {
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let parameter = Self.samplingParameters.first(where: { $0.name == parts[0] })
            else { continue }
            self[keyPath: parameter.keyPath] = parts[1]
        }
    }
}
