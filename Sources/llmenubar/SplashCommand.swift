// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation

/// Builds the `splash serve` invocation for a configuration.
///
/// Keeping this separate from `ProcessManager` makes the exact argument list
/// visible to Settings and unit-testable without launching a model.
enum SplashCommand {
    /// The host names Splash accepts in a request's Host header: the ones chosen,
    /// and, when it listens on every interface, this Mac's own network names.
    /// Splash allows only localhost by default, so without them the other-device
    /// addresses the app offers would be refused. The names are read at launch;
    /// a changed address takes effect at the next start.
    static func allowedHosts(
        for config: ServerConfiguration.Config,
        names: () -> LocalNetworkNames
    ) -> [String] {
        var hosts = SplashOptionValues.items(config.allowedHosts)
        if ListenAddress(config.host).isUnspecified {
            let own = names()
            for name in [own.hostName, own.ipv4].compactMap({ $0 })
            where !hosts.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                hosts.append(name)
            }
        }
        return hosts
    }

    /// The arguments after the executable. An option still at Splash's own
    /// default is left off, so the command shows only what the user chose.
    static func arguments(
        configuration config: ServerConfiguration.Config,
        networkNames: () -> LocalNetworkNames = { LocalNetworkNames.current() }
    ) -> [String] {
        var args = ["serve", "--model", config.modelArgument]

        switch config.modelSource {
        case .huggingFace:
            if !config.revision.isEmpty { args += ["--revision", config.revision] }
        case .local:
            args += ["--model-dir", PathText.expandingTilde(config.modelPath)]
            if !config.languageOnly, !config.visionProjectorPath.isEmpty {
                args += ["--mmproj", PathText.expandingTilde(config.visionProjectorPath)]
            }
        }
        if !config.draftModel.isEmpty {
            args += ["--draft-model", PathText.expandingTilde(config.draftModel)]
        }
        if config.modelSource == .huggingFace {
            valued("--draft-revision", config.draftRevision, into: &args)
        }
        if config.languageOnly { args.append("--language-only") }
        if config.offline { args.append("--offline") }

        // Network and access.
        args += ["--host", ListenAddress(config.host).bare, "--port", String(config.port)]
        for name in allowedHosts(for: config, names: networkNames) {
            args += ["--allowed-host", name]
        }
        for origin in SplashOptionValues.items(config.allowedOrigins) {
            args += ["--allowed-origin", origin]
        }
        if !config.chatPageEnabled { args.append("--no-webui") }

        // Memory and context.
        valued("--max-memory", config.maxMemory, into: &args)
        valued("--max-context", config.maxContext, into: &args)
        valued("--ple-memory", config.pleMemory, into: &args)
        valued("--expert-memory", config.expertMemory, into: &args)
        valued("--sparse-kv-memory", config.sparseKVMemory, into: &args)
        if let weights = config.weights.argument { args += ["--weights", weights] }
        if let format = config.kvFormat.argument { args += ["--kv-format", format] }
        if let format = config.stateFormat.argument { args += ["--state-format", format] }
        if let storage = config.cachedStates.argument { args += ["--cached-states", storage] }
        valued("--idle-release", config.idleRelease, into: &args)
        if config.disableANE { args.append("--disable-ane") }
        if config.recalibrateANE { args.append("--recalibrate-ane") }
        if let activations = config.activations.argument { args += ["--activations", activations] }

        // SSD cache.
        valued("--max-cache-disk", SplashOptionValues.plainWholeNumber(config.maxCacheDisk), into: &args)
        valued("--max-cache-disk-writes", SplashOptionValues.plainWholeNumber(config.maxCacheDiskWrites), into: &args)
        if config.persistentCache {
            args.append("--persistent-cache")
            if !config.cacheDirectory.isEmpty {
                args += ["--cache-dir", PathText.expandingTilde(config.cacheDirectory)]
            }
        }

        // API.
        let aliases = SplashOptionValues.items(config.servedModelNames)
        for alias in aliases { args += ["--served-model-name", alias] }
        if config.announceServedName, !aliases.isEmpty { args.append("--announce-served-name") }
        if let effort = config.reasoningEffort.argument {
            let flag = config.reasoningScope == .everyRequest
                ? "--reasoning-effort" : "--default-reasoning-effort"
            args += [flag, effort]
        }
        valued("--thinking-token-budget", config.thinkingTokenBudget, into: &args)
        valued("--thinking-end-text", config.thinkingEndText, into: &args)
        if !config.chatTemplatePath.isEmpty {
            args += ["--chat-template-file", PathText.expandingTilde(config.chatTemplatePath)]
        }

        for item in config.samplingArguments { args += ["--sampling-default", item] }

        // Requests.
        valued("--max-request-size", config.maxRequestSize, into: &args)
        valued("--max-image-pixels", config.maxImagePixels, into: &args)
        valued("--request-timeout", config.requestTimeout, into: &args)
        valued("--shutdown-timeout", SplashOptionValues.plainWholeNumber(config.shutdownTimeout), into: &args)
        valued("--queue-size", config.queueSize, into: &args)
        valued("--max-concurrent-requests", config.maxConcurrentRequests, into: &args)
        valued("--decode-share", config.decodeShare, into: &args)
        if let rows = config.verifyRows.argument { args += ["--verify-rows", rows] }
        if config.allowIdleSleep { args.append("--allow-idle-sleep") }

        return args
    }

    private static func valued(_ flag: String, _ text: String, into args: inout [String]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { args += [flag, trimmed] }
    }

    /// The environment variable that would make Splash refuse the effort this
    /// configuration puts on the command line. Splash takes the effort for
    /// every request and the effort for requests that set none as separate
    /// options, each with its own variable, and refuses a launch that has one
    /// of each. The choice made in Settings wins, so the other kind's variable,
    /// inherited or written in the environment text, is left out.
    static func conflictingEffortVariable(configuration: ServerConfiguration.Config) -> String? {
        guard configuration.reasoningEffort.argument != nil else { return nil }
        return configuration.reasoningScope == .everyRequest
            ? "SPLASH_DEFAULT_REASONING_EFFORT" : "SPLASH_REASONING_EFFORT"
    }

    /// The variables a launch adds to the inherited environment: the lines of
    /// the environment setting, and the API key under the name Splash reads it
    /// by. The key goes here and never in `arguments`, which `ps` shows.
    static func environmentOverrides(
        configuration: ServerConfiguration.Config
    ) -> [(name: String, value: String)] {
        var overrides: [(name: String, value: String)] = []
        overrides += EnvironmentText.parse(configuration.environment).map { ($0.name, $0.value) }
        // The folder chosen here wins over every other setting of the cache.
        let cache = configuration.modelCacheDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if configuration.modelSource == .huggingFace, !cache.isEmpty {
            overrides.append(("HF_HUB_CACHE", PathText.expandingTilde(cache)))
        }
        if let conflict = conflictingEffortVariable(configuration: configuration) {
            overrides.removeAll { $0.name == conflict }
        }
        // The switch on the Diagnostics pane wins over a line of the same name.
        if configuration.crashTrace {
            overrides.removeAll { $0.name == "SPLASH_CRASH_TRACE" }
            overrides.append(("SPLASH_CRASH_TRACE", "1"))
        }
        // The token chosen here wins over an HF_TOKEN line in the environment
        // text. Without one the engine finds the token `hf auth login` saved.
        let token = configuration.huggingFaceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if configuration.modelSource == .huggingFace, !token.isEmpty {
            overrides.removeAll { $0.name == "HF_TOKEN" }
            overrides.append(("HF_TOKEN", token))
        }
        if !configuration.apiKey.isEmpty {
            overrides.append((EnvironmentText.reservedName, configuration.apiKey))
        }
        return overrides
    }

    /// The environment Splash runs in: what the app inherited, with the
    /// overrides on top. A Mac app started from the Dock or at login has no
    /// `SPLASH_*` variables of its own unless the user set them for the whole
    /// login session on purpose, so those pass through unchanged.
    static func launchEnvironment(
        configuration: ServerConfiguration.Config,
        launcher: SplashLauncher? = nil,
        inheriting base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        for (name, value) in launcher?.environment ?? [:] {
            environment[name] = value
        }
        if let conflict = conflictingEffortVariable(configuration: configuration) {
            environment.removeValue(forKey: conflict)
        }
        for (name, value) in environmentOverrides(configuration: configuration) {
            environment[name] = value
        }
        return environment
    }

    /// Human-readable shell-style preview used by Settings. This is a display
    /// string, not a shell command executed by the app. The API key and other
    /// secret values are shown as placeholders: the preview is copied and
    /// pasted around, so a copy needs its secrets put back by hand.
    static func preview(configuration: ServerConfiguration.Config) -> String {
        let executable = PathText.expandingTilde(configuration.splashPath)
        // The desktop app is run through its own Python, so the preview shows
        // that command: it is what the app will start.
        var launcher: SplashLauncher?
        if case .success(let resolved) = SplashLauncher.resolve(path: executable) { launcher = resolved }
        var overrides = (launcher?.environment ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        overrides += environmentOverrides(configuration: configuration)
        let assignments = overrides.map { name, value in
            let hidden = name == EnvironmentText.reservedName || EnvironmentText.isSecret(name)
            let shown = hidden ? "REDACTED" : PathText.shellQuoted(value)
            return "\(name)=\(shown)"
        }
        let program = launcher?.commandLine([]) ?? [executable.isEmpty ? "splash" : executable]
        let words = program + arguments(configuration: configuration)
        let command = (assignments + words.map(PathText.shellQuoted)).joined(separator: " ")
        let log = PathText.shellQuoted(PathText.expandingTilde(configuration.logPath))
        return "\(command) > \(log) 2>&1"
    }
}
