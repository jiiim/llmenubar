// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest

@testable import llmenubar

final class SplashCommandTests: XCTestCase {
    private func base() -> ServerConfiguration.Config {
        var config = ServerConfiguration.Config()
        config.splashPath = "/opt/homebrew/bin/splash"
        config.huggingFaceModel = "unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M"
        return config
    }

    func testDefaultsGiveTheMinimalHuggingFaceCommand() {
        XCTAssertEqual(
            SplashCommand.arguments(configuration: base()),
            [
                "serve", "--model", "unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M",
                "--host", "127.0.0.1", "--port", "8000",
            ]
        )
    }

    func testLocalFilesUseModelDirWithALocalName() {
        var config = base()
        config.modelSource = .local
        config.modelPath = "/models/Qwen3.8-27B-UD-Q4_K_M.gguf"
        config.visionProjectorPath = "/models/mmproj-BF16.gguf"
        config.draftModel = "/models/Qwen3.8-27B-DFlash2"
        // A repository set earlier belongs to the other source.
        config.revision = "main"

        XCTAssertEqual(
            SplashCommand.arguments(configuration: config),
            [
                "serve", "--model", "local/Qwen3.8-27B-UD-Q4_K_M",
                "--model-dir", "/models/Qwen3.8-27B-UD-Q4_K_M.gguf",
                "--mmproj", "/models/mmproj-BF16.gguf",
                "--draft-model", "/models/Qwen3.8-27B-DFlash2",
                "--host", "127.0.0.1", "--port", "8000",
            ]
        )
    }

    func testALocalModelIsServedUnderTheNameTheUserGave() {
        var config = base()
        config.modelSource = .local
        config.modelPath = "/models/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf"
        XCTAssertEqual(config.modelArgument, "local/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004")

        config.localModelName = "local/huihui-v2-q4"
        let arguments = SplashCommand.arguments(configuration: config)
        XCTAssertEqual(arguments[1...2], ["--model", "local/huihui-v2-q4"])

        // A Hugging Face model keeps its own ID.
        config.modelSource = .huggingFace
        XCTAssertEqual(config.modelArgument, "unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M")
    }

    func testTheAPIKeyAndEnvironmentGoInTheEnvironmentNeverTheArguments() {
        var config = base()
        config.apiKey = "llm-secret-key"
        config.environment = "SPLASH_CRASH_TRACE=1\n# a comment\n\nOTHER=a=b"

        let arguments = SplashCommand.arguments(configuration: config)
        XCTAssertFalse(arguments.contains { $0.contains("llm-secret-key") }, "the key must stay off the command line")
        XCTAssertFalse(arguments.contains("--api-key"))

        let environment = SplashCommand.launchEnvironment(configuration: config, inheriting: ["PATH": "/usr/bin", "OTHER": "old"])
        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["SPLASH_API_KEY"], "llm-secret-key")
        XCTAssertEqual(environment["SPLASH_CRASH_TRACE"], "1")
        XCTAssertEqual(environment["OTHER"], "a=b", "the value is everything after the first =")
    }

    func testAnInheritedKeyPassesThroughUnlessTheAppSetsOne() {
        var config = base()
        let inherited = ["SPLASH_API_KEY": "from-the-login-session"]
        XCTAssertEqual(SplashCommand.launchEnvironment(configuration: config, inheriting: inherited)["SPLASH_API_KEY"],
                       "from-the-login-session")
        config.apiKey = "from-the-app"
        XCTAssertEqual(SplashCommand.launchEnvironment(configuration: config, inheriting: inherited)["SPLASH_API_KEY"],
                       "from-the-app")
    }

    func testThePreviewShowsTheEnvironmentButNotTheKey() {
        var config = base()
        config.apiKey = "llm-secret-key"
        config.environment = "SPLASH_CRASH_TRACE=1\nNOTE=two words"
        let preview = SplashCommand.preview(configuration: config)
        XCTAssertTrue(preview.hasPrefix("SPLASH_CRASH_TRACE=1 NOTE='two words' SPLASH_API_KEY=REDACTED /opt/homebrew/bin/splash serve "), preview)
        XCTAssertFalse(preview.contains("llm-secret-key"))
    }

    func testTextOnlyDropsTheProjectorAndHubRevisionAppliesToHubOnly() {
        var local = base()
        local.modelSource = .local
        local.modelPath = "/models/m.gguf"
        local.visionProjectorPath = "/models/mmproj.gguf"
        local.languageOnly = true
        let localArguments = SplashCommand.arguments(configuration: local)
        XCTAssertFalse(localArguments.contains("--mmproj"))
        XCTAssertTrue(localArguments.contains("--language-only"))

        var hub = base()
        hub.revision = "v2"
        hub.modelPath = "/models/ignored.gguf"
        let hubArguments = SplashCommand.arguments(configuration: hub)
        XCTAssertEqual(
            Array(hubArguments.prefix(5)),
            ["serve", "--model", "unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M", "--revision", "v2"]
        )
        XCTAssertFalse(hubArguments.contains("--model-dir"))
    }

    func testTheEffortGoesToTheOptionOfItsScope() {
        var config = ServerConfiguration.Config()
        config.huggingFaceModel = "owner/repo:Q4"
        config.reasoningEffort = .high
        let quiet: () -> LocalNetworkNames = { LocalNetworkNames(hostName: nil, ipv4: nil) }

        var args = SplashCommand.arguments(configuration: config, networkNames: quiet)
        XCTAssertTrue(args.contains("--default-reasoning-effort"))
        XCTAssertFalse(args.contains("--reasoning-effort"))

        config.reasoningScope = .everyRequest
        args = SplashCommand.arguments(configuration: config, networkNames: quiet)
        XCTAssertEqual(args[(args.firstIndex(of: "--reasoning-effort") ?? 0) + 1], "high")
        XCTAssertFalse(args.contains("--default-reasoning-effort"), "Splash refuses the two together")

        config.reasoningEffort = .off
        args = SplashCommand.arguments(configuration: config, networkNames: quiet)
        XCTAssertEqual(args[(args.firstIndex(of: "--reasoning-effort") ?? 0) + 1], "none")

        config.reasoningEffort = .modelDefault
        args = SplashCommand.arguments(configuration: config, networkNames: quiet)
        XCTAssertFalse(args.contains("--reasoning-effort"), "no effort, no option, whatever the scope")
    }

    /// Splash refuses a launch that carries both kinds of effort, from a flag or
    /// from a variable, so the choice made here removes the other kind's.
    func testTheEffortChosenHereDropsTheOtherKindsVariable() {
        var config = ServerConfiguration.Config()
        config.huggingFaceModel = "owner/repo:Q4"
        config.environment = "SPLASH_DEFAULT_REASONING_EFFORT=low\nSPLASH_REASONING_EFFORT=high\nOTHER=1"
        let inherited = [
            "SPLASH_DEFAULT_REASONING_EFFORT": "medium",
            "SPLASH_REASONING_EFFORT": "max",
            "PATH": "/usr/bin",
        ]

        // No effort chosen here: nothing is removed, and Splash is left to
        // judge what the user set.
        XCTAssertNil(SplashCommand.conflictingEffortVariable(configuration: config))
        var environment = SplashCommand.launchEnvironment(configuration: config, inheriting: inherited)
        XCTAssertEqual(environment["SPLASH_DEFAULT_REASONING_EFFORT"], "low")
        XCTAssertEqual(environment["SPLASH_REASONING_EFFORT"], "high")

        config.reasoningEffort = .low
        config.reasoningScope = .everyRequest
        XCTAssertEqual(SplashCommand.conflictingEffortVariable(configuration: config), "SPLASH_DEFAULT_REASONING_EFFORT")
        environment = SplashCommand.launchEnvironment(configuration: config, inheriting: inherited)
        XCTAssertNil(environment["SPLASH_DEFAULT_REASONING_EFFORT"], "inherited and written, both dropped")
        XCTAssertEqual(environment["SPLASH_REASONING_EFFORT"], "high", "the same kind stays; the flag outranks it")
        XCTAssertEqual(environment["OTHER"], "1")
        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertFalse(SplashCommand.environmentOverrides(configuration: config).contains { $0.name == "SPLASH_DEFAULT_REASONING_EFFORT" })
        XCTAssertFalse(SplashCommand.preview(configuration: config).contains("SPLASH_DEFAULT_REASONING_EFFORT"))

        config.reasoningScope = .requestsWithoutOne
        XCTAssertEqual(SplashCommand.conflictingEffortVariable(configuration: config), "SPLASH_REASONING_EFFORT")
        environment = SplashCommand.launchEnvironment(configuration: config, inheriting: inherited)
        XCTAssertNil(environment["SPLASH_REASONING_EFFORT"])
        XCTAssertEqual(environment["SPLASH_DEFAULT_REASONING_EFFORT"], "low")
    }

    func testAChatTemplateReachesTheCommandWithItsPathExpanded() {
        var config = ServerConfiguration.Config()
        config.huggingFaceModel = "owner/repo:Q4"
        XCTAssertFalse(SplashCommand.arguments(configuration: config).contains("--chat-template-file"))

        config.chatTemplatePath = "~/templates/mine.jinja"
        let args = SplashCommand.arguments(configuration: config)
        let at = args.firstIndex(of: "--chat-template-file")
        XCTAssertNotNil(at)
        XCTAssertEqual(
            args[(at ?? 0) + 1],
            FileManager.default.homeDirectoryForCurrentUser.path + "/templates/mine.jinja"
        )
    }

    func testASocketHostIsGivenToSplashWithItsPathExpanded() {
        var config = ServerConfiguration.Config()
        config.huggingFaceModel = "owner/repo:Q4"
        config.host = "unix:~/splash.sock"
        let args = SplashCommand.arguments(configuration: config)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let at = args.firstIndex(of: "--host") ?? -1
        XCTAssertEqual(args[at + 1], "unix:" + home + "/splash.sock")
        XCTAssertFalse(args.contains("--allowed-host"), "a socket has no network names")
    }

    func testEveryOptionReachesTheCommandInGroupOrder() {
        var config = base()
        config.offline = true
        config.host = "0.0.0.0"
        config.port = 8123
        config.allowedHosts = "mymac.local, other.local"
        config.allowedOrigins = "https://a.example,*"
        config.chatPageEnabled = false
        config.maxMemory = "28G"
        config.maxContext = "100K"
        config.pleMemory = "2G"
        config.expertMemory = "off"
        config.sparseKVMemory = "1200M"
        config.kvFormat = .bf16
        config.stateFormat = .bf16
        config.cachedStates = .exact
        config.idleRelease = "30m"
        config.disableANE = true
        config.activations = .bf16
        config.maxCacheDisk = "16G"
        config.maxCacheDiskWrites = "200G"
        config.persistentCache = true
        config.cacheDirectory = "/Volumes/cache/splash"
        config.servedModelNames = "gpt-4o"
        config.announceServedName = true
        config.reasoningEffort = .off
        config.thinkingTokenBudget = "2048"
        config.thinkingEndText = "Now the answer."
        config.maxRequestSize = "64M"
        config.maxImagePixels = "1048576"
        config.requestTimeout = "30m"
        config.queueSize = "8"
        config.maxConcurrentRequests = "6"
        config.applySampling("temperature = 0.7, top_k=40")
        config.decodeShare = "0.25"
        config.verifyRows = .all
        config.allowIdleSleep = true

        XCTAssertEqual(
            // This Mac's own names would otherwise join the allowed hosts.
            SplashCommand.arguments(configuration: config, networkNames: { LocalNetworkNames(hostName: nil, ipv4: nil) }),
            [
                "serve", "--model", "unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M", "--offline",
                "--host", "0.0.0.0", "--port", "8123",
                "--allowed-host", "mymac.local", "--allowed-host", "other.local",
                "--allowed-origin", "https://a.example", "--allowed-origin", "*",
                "--no-webui",
                "--max-memory", "28G", "--max-context", "100K",
                "--ple-memory", "2G", "--expert-memory", "off", "--sparse-kv-memory", "1200M",
                "--kv-format", "bf16", "--state-format", "bf16", "--cached-states", "exact",
                "--idle-release", "30m", "--disable-ane", "--activations", "bf16",
                "--max-cache-disk", "16G", "--max-cache-disk-writes", "200G",
                "--persistent-cache", "--cache-dir", "/Volumes/cache/splash",
                "--served-model-name", "gpt-4o", "--announce-served-name",
                "--default-reasoning-effort", "none",
                "--thinking-token-budget", "2048", "--thinking-end-text", "Now the answer.",
                "--sampling-default", "temperature=0.7", "--sampling-default", "top_k=40",
                "--max-request-size", "64M", "--max-image-pixels", "1048576",
                "--request-timeout", "30m", "--queue-size", "8", "--max-concurrent-requests", "6",
                "--decode-share", "0.25",
                "--verify-rows", "all", "--allow-idle-sleep",
            ]
        )
    }

    func testTheNeuralEngineIsRecalibratedAfterTheGPUOnlyOption() throws {
        var config = base()
        config.recalibrateANE = true
        let args = SplashCommand.arguments(configuration: config, networkNames: { LocalNetworkNames(hostName: nil, ipv4: nil) })
        let recalibrate = try XCTUnwrap(args.firstIndex(of: "--recalibrate-ane"))
        XCTAssertEqual(args.firstIndex(of: "--disable-ane").map { _ in recalibrate - 1 }, nil, "off unless asked")
        config.disableANE = true
        let both = SplashCommand.arguments(configuration: config, networkNames: { LocalNetworkNames(hostName: nil, ipv4: nil) })
        XCTAssertEqual(try XCTUnwrap(both.firstIndex(of: "--recalibrate-ane")), try XCTUnwrap(both.firstIndex(of: "--disable-ane")) + 1)
        XCTAssertFalse(SplashCommand.arguments(configuration: base(), networkNames: { LocalNetworkNames(hostName: nil, ipv4: nil) }).contains("--recalibrate-ane"))
    }

    func testDependentOptionsAreLeftOffWhenTheirParentIsOff() {
        var config = base()
        config.cacheDirectory = "/tmp/cache"          // needs Keep after stopping
        config.announceServedName = true              // needs an other name

        let arguments = SplashCommand.arguments(configuration: config)
        XCTAssertFalse(arguments.contains("--cache-dir"))
        XCTAssertFalse(arguments.contains("--announce-served-name"))
    }

    func testTheHostIsPassedWithoutBrackets() {
        var config = base()
        config.host = "[::1]"
        let arguments = SplashCommand.arguments(configuration: config)
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--host")! + 1], "::1")
    }

    func testTildePathsAreExpandedForTheChild() {
        var config = base()
        config.modelSource = .local
        config.modelPath = "~/models/m.gguf"
        let arguments = SplashCommand.arguments(configuration: config)
        let directory = arguments[arguments.firstIndex(of: "--model-dir")! + 1]
        XCTAssertEqual(directory, NSHomeDirectory() + "/models/m.gguf")
    }

    func testPreviewQuotesWhatAShellWouldSplitAndRedirectsToTheLog() {
        var config = base()
        config.splashPath = "/Users/me/My Tools/splash"
        config.logPath = "/tmp/llm log/splash.log"
        config.thinkingEndText = "It's time"

        let preview = SplashCommand.preview(configuration: config)
        XCTAssertTrue(preview.hasPrefix("'/Users/me/My Tools/splash' serve --model "))
        XCTAssertTrue(preview.contains("--thinking-end-text 'It'\\''s time'"))
        XCTAssertTrue(preview.hasSuffix("> '/tmp/llm log/splash.log' 2>&1"))
    }

    func testPreviewNamesSplashBeforeAnExecutableIsChosen() {
        var config = base()
        config.splashPath = ""
        XCTAssertTrue(SplashCommand.preview(configuration: config).hasPrefix("splash serve "))
    }

    func testThePreviewHidesSecretValuesAndShowsTheRest() {
        var config = ServerConfiguration.Config()
        config.splashPath = "/opt/homebrew/bin/splash"
        config.huggingFaceModel = "owner/repo:Q4"
        config.environment = "HF_TOKEN=hf_abc123\nSPLASH_CRASH_TRACE=1"
        let preview = SplashCommand.preview(configuration: config)
        XCTAssertFalse(preview.contains("hf_abc123"), preview)
        XCTAssertTrue(preview.contains("HF_TOKEN=REDACTED"), preview)
        XCTAssertTrue(preview.contains("SPLASH_CRASH_TRACE=1"), preview)
    }

    func testWhichNamesAreSecret() {
        for name in ["HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "SPLASH_API_KEY", "my_password", "AWS_SECRET_ACCESS_KEY", "AUTH_HEADER"] {
            XCTAssertTrue(EnvironmentText.isSecret(name), name)
        }
        for name in ["SPLASH_CRASH_TRACE", "HF_HOME", "PATH", "HF_HUB_OFFLINE"] {
            XCTAssertFalse(EnvironmentText.isSecret(name), name)
        }
    }

    private let ownNames = LocalNetworkNames(hostName: "Jims-Mac.local", ipv4: "192.168.1.20")

    /// Splash refuses a request whose Host is not localhost or an allowed host,
    /// so the other-device addresses work only if the Mac's names are allowed.
    func testAnAllNetworksServerAllowsTheMacsOwnNames() {
        var config = ServerConfiguration.Config()
        config.host = "0.0.0.0"
        config.allowedHosts = "other.local, jims-mac.local"
        let args = SplashCommand.arguments(configuration: config, networkNames: { self.ownNames })
        var hosts: [String] = []
        for (index, argument) in args.enumerated() where argument == "--allowed-host" { hosts.append(args[index + 1]) }
        XCTAssertEqual(hosts, ["other.local", "jims-mac.local", "192.168.1.20"], "no duplicate of a name already given")
    }

    func testAServerOnOneAddressAddsNoHosts() {
        for host in ["127.0.0.1", "192.168.1.5"] {
            var config = ServerConfiguration.Config()
            config.host = host
            let args = SplashCommand.arguments(configuration: config, networkNames: { XCTFail("not needed"); return self.ownNames })
            XCTAssertFalse(args.contains("--allowed-host"), host)
        }
    }
}
