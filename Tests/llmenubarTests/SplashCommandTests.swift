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
                "--kv-format", "bf16", "--state-format", "bf16",
                "--idle-release", "30m", "--disable-ane", "--activations", "bf16",
                "--max-cache-disk", "16G", "--max-cache-disk-writes", "200G",
                "--persistent-cache", "--cache-dir", "/Volumes/cache/splash",
                "--served-model-name", "gpt-4o", "--announce-served-name",
                "--default-reasoning-effort", "none",
                "--thinking-token-budget", "2048", "--thinking-end-text", "Now the answer.",
                "--max-request-size", "64M", "--max-image-pixels", "1048576",
                "--request-timeout", "30m", "--queue-size", "8", "--decode-share", "0.25",
                "--verify-rows", "all", "--allow-idle-sleep",
            ]
        )
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
