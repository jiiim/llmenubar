// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Derived state

/// What the files a draft names say about themselves. Reading them touches the
/// disk and runs the `splash` executable, so this is computed off the main
/// thread and held beside the draft rather than recomputed per keystroke.
struct SplashDerivedState: Equatable, Sendable {
    var build: SplashBuild = .unknown
    /// Why the selected executable cannot be used, if it cannot.
    var splashIssue: String?
    /// Why the local model files cannot be served, if they cannot.
    var modelIssue: SplashModel.LocalModelIssue?
    var visionProjectorIssue: String?
    var draftIssue: String?
    var chatTemplateIssue: String?

    /// Nothing inspected: no file or executable problem is known.
    static let uninspected = SplashDerivedState()

    /// Read everything `config` names. Blocks; call it off the main thread.
    static func compute(for config: ServerConfiguration.Config) -> SplashDerivedState {
        var state = SplashDerivedState()

        if config.hasSplash {
            (state.build, state.splashIssue) = inspectSplash(atPath: config.splashPath)
        }

        if !config.chatTemplatePath.isEmpty {
            let path = PathText.expandingTilde(config.chatTemplatePath)
            if !FileManager.default.isReadableRegularFile(atPath: path) {
                state.chatTemplateIssue = "Choose a readable chat template file."
            }
        }

        guard config.modelSource == .local else {
            state.draftIssue = hubDraftIssue(config)
            return state
        }
        if config.hasModel {
            if case .failure(let issue) = SplashModel.inspectLocalModel(atPath: config.modelPath) {
                state.modelIssue = issue
            }
        }
        if !config.visionProjectorPath.isEmpty, !config.languageOnly {
            let path = PathText.expandingTilde(config.visionProjectorPath)
            if !FileManager.default.isReadableRegularFile(atPath: path) {
                state.visionProjectorIssue = "Choose a readable GGUF vision projector file."
            } else if !SplashModel.hasGGUFMagic(atPath: path) {
                state.visionProjectorIssue = "That file is not a GGUF."
            }
        }
        if !config.draftModel.isEmpty {
            let path = PathText.expandingTilde(config.draftModel)
            var isDirectory: ObjCBool = false
            if !(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue) {
                state.draftIssue = "Choose the folder of a DFlash2 draft."
            }
        }
        return state
    }

    /// Run the executable at `path` and report what it is, with the reason it
    /// cannot be used when it cannot. Blocks; call it off the main thread.
    static func inspectSplash(atPath path: String) -> (build: SplashBuild, issue: String?) {
        let launcher: SplashLauncher
        switch SplashLauncher.resolve(path: path) {
        case .failure(let issue): return (.unknown, issue.message)
        case .success(let resolved): launcher = resolved
        }
        let build = SplashBuild.inspecting(launcher: launcher)
        switch build.identity {
        case .unknown: return (build, "This file could not be run.")
        case .notSplash: return (build, "Choose splash, not another executable.")
        case .splash: return (build, nil)
        }
    }

    private static func hubDraftIssue(_ config: ServerConfiguration.Config) -> String? {
        guard !config.draftModel.isEmpty, !SplashModel.isRepositoryID(config.draftModel) else { return nil }
        return "Enter a draft as owner/repo."
    }
}

// MARK: - Validation

extension ServerConfiguration.Config {
    /// Identifies the field an error belongs to, so Settings can place a message
    /// next to the control that produced it. A typed enum rather than bare
    /// strings: a mismatch between the validator's key and the row's key would
    /// otherwise just silently hide the error.
    enum Field: String, CaseIterable, Hashable {
        case splashPath
        case huggingFaceModel, modelPath, localModelName, visionProjectorPath, draftModel, revision
        case modelCacheDirectory, chatTemplatePath
        case host, port, allowedHosts, allowedOrigins, apiKey, huggingFaceToken
        case maxMemory, maxContext, pleMemory, expertMemory, sparseKVMemory, idleRelease, activations, cachedStates, recalibrateANE
        case maxCacheDisk, maxCacheDiskWrites, cacheDirectory
        case servedModelNames, reasoningEffort, thinkingTokenBudget, thinkingEndText
        case maxRequestSize, maxImagePixels, requestTimeout, queueSize, maxConcurrentRequests, decodeShare
        case samplingTemperature, samplingTopP, samplingTopK, samplingMinP
        case samplingPresencePenalty, samplingFrequencyPenalty, samplingRepetitionPenalty
        case logPath, logMaxSizeMB, environment
    }

    /// Every field the draft gets wrong, with the message for each. Empty means
    /// the draft can be applied and launched.
    func validationErrors(derived: SplashDerivedState = .uninspected) -> [Field: String] {
        var errors: [Field: String] = [:]
        func fail(_ field: Field, _ message: String) {
            if errors[field] == nil { errors[field] = message }
        }

        // Splash.
        if !hasSplash {
            fail(.splashPath, "Choose the splash executable.")
        } else if !PathText.isAbsolute(splashPath) {
            fail(.splashPath, "Choose the executable with the Choose button.")
        } else if let issue = derived.splashIssue {
            fail(.splashPath, issue)
        }

        // Model.
        switch modelSource {
        case .huggingFace:
            if huggingFaceModel.isEmpty {
                fail(.huggingFaceModel, "Enter a model as owner/repo or owner/repo:VARIANT.")
            } else if !SplashModel.isModelID(huggingFaceModel) {
                fail(.huggingFaceModel, "Use owner/repo or owner/repo:VARIANT, such as unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M.")
            }
        case .local:
            if modelPath.isEmpty {
                fail(.modelPath, "Choose a GGUF file, or the folder of a model.")
            } else if !PathText.isAbsolute(modelPath) {
                fail(.modelPath, "Choose the model with the Choose button.")
            } else if let issue = derived.modelIssue {
                fail(.modelPath, issue.message)
            }
            if !localModelName.isEmpty, !SplashModel.isRepositoryID(localModelName) {
                fail(.localModelName, "Use a name such as local/my-model.")
            }
            if !languageOnly, !visionProjectorPath.isEmpty {
                if !PathText.isAbsolute(visionProjectorPath) {
                    fail(.visionProjectorPath, "Choose the projector with the Choose button.")
                } else if let issue = derived.visionProjectorIssue {
                    fail(.visionProjectorPath, issue)
                }
            }
        }
        if !draftModel.isEmpty {
            switch modelSource {
            case .huggingFace:
                if !SplashModel.isRepositoryID(draftModel) {
                    fail(.draftModel, "Enter a draft as owner/repo.")
                }
            case .local:
                if !PathText.isAbsolute(draftModel) {
                    fail(.draftModel, "Choose the draft folder with the Choose button.")
                } else if let issue = derived.draftIssue {
                    fail(.draftModel, issue)
                }
            }
        }
        if !revision.isEmpty {
            if modelSource == .local {
                fail(.revision, "A revision applies to a Hugging Face model.")
            } else if revision.contains(where: \.isWhitespace) || revision.hasPrefix("-") {
                fail(.revision, "Enter a branch, tag or commit.")
            }
        }

        // Network and access.
        let address = ListenAddress(host)
        if address.kind == .unixSocket {
            // A path may hold spaces, and it names no port.
            if let issue = address.socketIssue {
                fail(.host, issue)
            } else if let path = address.socketPath {
                var isDirectory: ObjCBool = false
                let folder = (path as NSString).deletingLastPathComponent
                if !(FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory) && isDirectory.boolValue) {
                    fail(.host, "The folder for the socket does not exist: \(folder).")
                } else if !derived.build.supportsUnixSocket {
                    fail(.host, "This engine cannot listen on a UNIX socket. Update Splash to 1.7.0 or later.")
                }
            }
        } else if address.configured.isEmpty {
            fail(.host, "Enter an address, such as 127.0.0.1 or 0.0.0.0.")
        } else if address.configured.contains(where: \.isWhitespace) {
            fail(.host, "An address cannot contain spaces.")
        } else if address.isIPv6, !ListenAddress.acceptsIPv6 {
            fail(.host, "Splash listens on IPv4 addresses only. Use an address such as 127.0.0.1 or 0.0.0.0.")
        } else if !address.isWellFormed {
            if address.configured.contains(":") {
                fail(.host, "Enter the address without a port. The port is set below.")
            } else {
                fail(.host, "Use an IPv4 address or a host name of letters, digits, dots and hyphens.")
            }
        }
        if !(ConfigurationLimits.minPort...ConfigurationLimits.maxPort).contains(port) {
            fail(.port, "Use a port from \(ConfigurationLimits.minPort) to \(ConfigurationLimits.maxPort).")
        }
        for origin in SplashOptionValues.items(allowedOrigins) where !SplashOptionValues.isOrigin(origin) {
            fail(.allowedOrigins, "“\(origin)” is not an origin such as http://localhost:3000.")
        }
        // Splash compares each name with the Host header, which has no port, path
        // or spaces; a leading dash would be read as an option.
        for name in SplashOptionValues.items(allowedHosts)
        where name.hasPrefix("-") || name.contains("/") || !ListenAddress(name).isWellFormed {
            fail(.allowedHosts, "“\(name)” is not a host name. Give the name alone, without a port.")
        }
        if thinkingEndText.hasPrefix("-") {
            fail(.thinkingEndText, "Text that starts with a dash is read as an option. Start it with a word.")
        }
        if !apiKey.isEmpty, apiKey.unicodeScalars.contains(where: { $0.value <= 32 || $0.value >= 127 }) {
            fail(.apiKey, "A key can use only visible ASCII characters, with no spaces.")
        }
        if !huggingFaceToken.isEmpty, huggingFaceToken.unicodeScalars.contains(where: { $0.value <= 32 || $0.value >= 127 }) {
            fail(.huggingFaceToken, "A token can use only visible ASCII characters, with no spaces.")
        }

        // Memory and context.
        check(maxMemory, .maxMemory, "Use auto, or a size such as 28G.", &errors) {
            SplashOptionValues.isAuto($0) || SplashOptionValues.byteCount($0) != nil
        }
        check(maxContext, .maxContext, "Use auto, or a token count up to 1010000 such as 100K or 1M.", &errors) {
            SplashOptionValues.isAuto($0) || SplashOptionValues.contextTokens($0) != nil
        }
        check(pleMemory, .pleMemory, "Use auto, off, or a size such as 2G.", &errors) {
            SplashOptionValues.isAuto($0) || $0.lowercased() == "off" || SplashOptionValues.byteCount($0) != nil
        }
        check(expertMemory, .expertMemory, "Use auto, off, or a size such as 16G.", &errors) {
            SplashOptionValues.isAuto($0) || $0.lowercased() == "off" || SplashOptionValues.byteCount($0) != nil
        }
        check(sparseKVMemory, .sparseKVMemory, "Use auto, or a size such as 1200M.", &errors) {
            SplashOptionValues.isAuto($0) || SplashOptionValues.byteCount($0) != nil
        }
        check(idleRelease, .idleRelease, "Use off, or a duration such as 30m, 2h or 600.", &errors) {
            $0.lowercased() == "off" || SplashOptionValues.seconds($0) != nil
        }

        // SSD cache.
        check(maxCacheDisk, .maxCacheDisk, "Use auto, 0 to turn it off, or a size such as 16G.", &errors) {
            SplashOptionValues.isAuto($0) || $0 == "0" || SplashOptionValues.byteCount($0) != nil
        }
        check(maxCacheDiskWrites, .maxCacheDiskWrites, "Use 0 for no limit, or a size such as 200G.", &errors) {
            $0 == "0" || SplashOptionValues.byteCount($0) != nil
        }
        if persistentCache, !cacheDirectory.isEmpty, !PathText.isAbsolute(cacheDirectory) {
            fail(.cacheDirectory, "Choose the folder with the Choose button.")
        }

        // Where Hugging Face models download.
        if modelSource == .huggingFace, !modelCacheDirectory.isEmpty {
            let path = PathText.expandingTilde(modelCacheDirectory)
            var isDirectory: ObjCBool = false
            if !PathText.isAbsolute(modelCacheDirectory) {
                fail(.modelCacheDirectory, "Choose the folder with the Choose button.")
            } else if ModelCache.freeBytes(at: path) == nil {
                fail(.modelCacheDirectory, "That folder's disk is not connected.")
            } else if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
                if !isDirectory.boolValue {
                    fail(.modelCacheDirectory, "Choose a folder, not a file.")
                } else if !FileManager.default.isWritableFile(atPath: path) {
                    fail(.modelCacheDirectory, "That folder cannot be written to.")
                }
            }
        }

        // The chat template that replaces the model's own.
        if !chatTemplatePath.isEmpty {
            if !PathText.isAbsolute(chatTemplatePath) {
                fail(.chatTemplatePath, "Choose the template with the Choose button.")
            } else if let issue = derived.chatTemplateIssue {
                fail(.chatTemplatePath, issue)
            }
        }

        // API.
        for name in SplashOptionValues.items(servedModelNames) where !SplashOptionValues.isModelAlias(name) {
            fail(.servedModelNames, "“\(name)” cannot be a model name: no spaces or URL characters, and no leading dash.")
        }
        check(thinkingTokenBudget, .thinkingTokenBudget, "Use a whole number of tokens.", &errors) {
            SplashOptionValues.wholeNumber($0) != nil
        }

        // Requests.
        check(maxRequestSize, .maxRequestSize, "Use a size such as 128M.", &errors) {
            SplashOptionValues.byteCount($0) != nil
        }
        check(maxImagePixels, .maxImagePixels,
              "Use a number from \(SplashOptionValues.imagePixelRange.lowerBound) to \(SplashOptionValues.imagePixelRange.upperBound).",
              &errors) {
            SplashOptionValues.wholeNumber($0).map(SplashOptionValues.imagePixelRange.contains) ?? false
        }
        check(requestTimeout, .requestTimeout, "Use a duration such as 30m, 2h or 3600.", &errors) {
            SplashOptionValues.seconds($0) != nil
        }
        check(queueSize, .queueSize, "Use a whole number greater than 0.", &errors) {
            (SplashOptionValues.pythonInteger($0) ?? 0) > 0
        }
        check(maxConcurrentRequests, .maxConcurrentRequests, "Use a whole number from \(SplashOptionValues.concurrentRequestRange.lowerBound) to \(SplashOptionValues.concurrentRequestRange.upperBound).", &errors) {
            SplashOptionValues.pythonInteger($0).map(SplashOptionValues.concurrentRequestRange.contains) ?? false
        }
        check(decodeShare, .decodeShare, "Use a number such as 0.5.", &errors) {
            SplashOptionValues.nonnegativeDecimal($0) != nil
        }

        if recalibrateANE, disableANE {
            fail(.recalibrateANE, "The Neural Engine is off, so there is nothing to calibrate. Turn off “Prefill on the GPU alone” or this.")
        }
        for parameter in Self.samplingParameters {
            if let issue = samplingIssue(parameter) { fail(parameter.field, issue) }
        }

        // Diagnostics.
        if logPath.isEmpty || !PathText.isAbsolute(logPath) {
            fail(.logPath, "Choose a folder for the log.")
        }
        if !(ConfigurationLimits.minLogSizeMB...ConfigurationLimits.maxLogSizeMB).contains(logMaxSizeMB) {
            fail(.logMaxSizeMB, "Use a size from \(ConfigurationLimits.minLogSizeMB) to \(ConfigurationLimits.maxLogSizeMB) MB.")
        }

        if let message = EnvironmentText.firstError(in: environment) {
            fail(.environment, message)
        }

        // Options the selected Splash does not take. Only a set option is
        // reported; an option left at Splash's default costs nothing.
        for (field, flag) in setOptions() where !derived.build.supports(flag) {
            fail(field, "This engine has no \(flag) option. Update the engine, or clear this setting.")
        }
        return errors
    }

    /// The first error in the order a launch would meet it, for the message a
    /// refused start shows.
    func firstValidationError(derived: SplashDerivedState = .uninspected) -> String? {
        let errors = validationErrors(derived: derived)
        return Field.allCases.lazy.compactMap { errors[$0] }.first
    }

    private func check(
        _ text: String,
        _ field: Field,
        _ message: String,
        _ errors: inout [Field: String],
        accepts: (String) -> Bool
    ) {
        guard !text.isEmpty, !accepts(text), errors[field] == nil else { return }
        errors[field] = message
    }

    /// The options of `serve` this configuration sets, with the field each came
    /// from.
    private func setOptions() -> [(Field, String)] {
        var options: [(Field, String)] = []
        func add(_ field: Field, _ flag: String, when isSet: Bool) {
            if isSet { options.append((field, flag)) }
        }
        add(.visionProjectorPath, "--mmproj", when: modelSource == .local && !languageOnly && !visionProjectorPath.isEmpty)
        add(.draftModel, "--draft-model", when: !draftModel.isEmpty)
        add(.revision, "--revision", when: modelSource == .huggingFace && !revision.isEmpty)
        add(.allowedHosts, "--allowed-host", when: !SplashOptionValues.items(allowedHosts).isEmpty)
        add(.allowedOrigins, "--allowed-origin", when: !SplashOptionValues.items(allowedOrigins).isEmpty)
        add(.pleMemory, "--ple-memory", when: !pleMemory.isEmpty)
        add(.expertMemory, "--expert-memory", when: !expertMemory.isEmpty)
        add(.sparseKVMemory, "--sparse-kv-memory", when: !sparseKVMemory.isEmpty)
        add(.maxCacheDiskWrites, "--max-cache-disk-writes", when: !maxCacheDiskWrites.isEmpty)
        add(.reasoningEffort, "--reasoning-effort",
            when: reasoningEffort != .modelDefault && reasoningScope == .everyRequest)
        add(.chatTemplatePath, "--chat-template-file", when: !chatTemplatePath.isEmpty)
        add(.thinkingTokenBudget, "--thinking-token-budget", when: !thinkingTokenBudget.isEmpty)
        add(.thinkingEndText, "--thinking-end-text", when: !thinkingEndText.isEmpty)
        add(.maxImagePixels, "--max-image-pixels", when: !maxImagePixels.isEmpty)
        add(.requestTimeout, "--request-timeout", when: !requestTimeout.isEmpty)
        add(.queueSize, "--queue-size", when: !queueSize.isEmpty)
        add(.maxConcurrentRequests, "--max-concurrent-requests", when: !maxConcurrentRequests.isEmpty)
        add(.decodeShare, "--decode-share", when: !decodeShare.isEmpty)
        for parameter in Self.samplingParameters {
            add(parameter.field, "--sampling-default", when: !self[keyPath: parameter.keyPath].isEmpty)
        }
        add(.recalibrateANE, "--recalibrate-ane", when: recalibrateANE)
        add(.activations, "--activations", when: activations != .standard)
        add(.cachedStates, "--cached-states", when: cachedStates != .standard)
        return options
    }
}
