// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import ServiceManagement

// MARK: - ServerConfiguration

/// Owns the user-editable configuration and its persistence.
///
/// The configuration models the single-Mac `splash serve` workflow: one Splash
/// process on the Mac the app runs on, serving one model.
final class ServerConfiguration {
    private var values = Config()
    private let defaults: UserDefaults
    private let secrets: SecretStore
    /// Secrets the keychain would not give back at load. They are left alone
    /// at save while the draft holds nothing for them, so a refused prompt
    /// cannot wipe a stored value.
    private var unreadableSecrets: Set<Secret> = []
    private(set) var showsPerformanceInMenuBar: Bool
    private(set) var keepsAwakeWhileRunning: Bool
    private(set) var confirmQuitWhileServerActive: Bool
    private(set) var autoRestartServer: Bool
    private(set) var recentSelections: RecentSelections
    /// The projector and draft each model family was last applied with.
    private(set) var familyMemory = ModelFamilyMemory()
    private let log = OSLog(subsystem: "com.jiiim.llmenubar", category: "config")

    init(defaults: UserDefaults = .standard, secrets: SecretStore = SecretStores.standard()) {
        self.defaults = defaults
        self.secrets = secrets
        showsPerformanceInMenuBar = defaults.bool(forKey: Self.performanceDisplayKey)
        keepsAwakeWhileRunning = defaults.bool(forKey: Self.keepAwakeKey)
        // Default-on, read rather than registered: `register(defaults:)` writes
        // a process-wide registration domain, so it would change the missing-key
        // answer for every other UserDefaults instance, suites included.
        // Deleting the key still restores the default.
        if defaults.object(forKey: Self.confirmQuitKey) == nil {
            confirmQuitWhileServerActive = true
        } else {
            confirmQuitWhileServerActive = defaults.bool(forKey: Self.confirmQuitKey)
        }
        if defaults.object(forKey: Self.autoRestartKey) == nil {
            autoRestartServer = true
        } else {
            autoRestartServer = defaults.bool(forKey: Self.autoRestartKey)
        }
        if let data = defaults.data(forKey: Self.recentSelectionsKey),
           let recents = try? JSONDecoder().decode(RecentSelections.self, from: data) {
            recentSelections = recents
        } else {
            recentSelections = RecentSelections()
        }
        if let data = defaults.data(forKey: Self.familyMemoryKey),
           let memory = try? JSONDecoder().decode(ModelFamilyMemory.self, from: data) {
            familyMemory = memory
        }
        loadConfig()
    }

    // MARK: Codable snapshot

    enum ModelSource: String, Codable, CaseIterable, Equatable {
        /// A Hugging Face model ID, which Splash downloads and keeps.
        case huggingFace
        /// A GGUF file or model folder on this Mac, loaded with `--model-dir`.
        case local
    }

    enum KVFormat: String, Codable, CaseIterable, Equatable {
        case standard, int8, bf16
        var argument: String? { self == .standard ? nil : rawValue }
    }

    enum StateFormat: String, Codable, CaseIterable, Equatable {
        case standard, fp32, bf16
        var argument: String? { self == .standard ? nil : rawValue }
    }

    /// How cached recurrent states are stored: Splash's `--cached-states`.
    enum CachedStates: String, Codable, CaseIterable, Equatable {
        case standard, int8, exact
        var argument: String? { self == .standard ? nil : rawValue }
    }

    enum Activations: String, Codable, CaseIterable, Equatable {
        case standard, bf16
        var argument: String? { self == .standard ? nil : rawValue }
    }

    enum ReasoningEffort: String, Codable, CaseIterable, Equatable {
        case modelDefault, off, minimal, low, medium, high, xhigh, max
        /// The value `--default-reasoning-effort` takes.
        var argument: String? {
            switch self {
            case .modelDefault: return nil
            case .off: return "none"
            default: return rawValue
            }
        }
    }

    /// Which requests the chosen thinking effort governs. Splash takes the two
    /// as separate options and refuses both together, so one choice picks the
    /// option the command carries.
    enum ReasoningScope: String, Codable, CaseIterable, Equatable {
        /// `--default-reasoning-effort`: a request that sets none.
        case requestsWithoutOne
        /// `--reasoning-effort`: every request, whatever it asks.
        case everyRequest
    }

    enum VerifyRows: String, Codable, CaseIterable, Equatable {
        case standard, auto, all
        var argument: String? { self == .standard ? nil : rawValue }
    }

    /// One persisted Codable value keeps migration and testing
    /// straightforward. Every text option left blank is left off the command
    /// line, so Splash chooses it.
    struct Config: Codable, Equatable {
        // Splash.
        var splashPath = ""

        // Model.
        var modelSource: ModelSource = .huggingFace
        var huggingFaceModel = ""
        var modelPath = ""
        /// The name the API reports for local files, such as
        /// `local/huihui-v2-q4`. Blank derives one from the file's name.
        var localModelName = ""
        /// A GGUF vision projector, for a model loaded from local files.
        var visionProjectorPath = ""
        /// A DFlash2 draft: a folder for local files, a repository otherwise.
        var draftModel = ""
        var revision = ""
        var languageOnly = false
        var offline = false
        /// Where Hugging Face models download to (`HF_HUB_CACHE`). Blank uses
        /// the user's Hugging Face setting, or its default.
        var modelCacheDirectory = ""

        // Network and access.
        var host = "127.0.0.1"
        var port = 8000
        var allowedHosts = ""
        var allowedOrigins = ""
        var chatPageEnabled = true
        /// Clients must send this key. Splash takes it in `SPLASH_API_KEY`,
        /// never on the command line, where other processes can read it.
        /// Kept in the keychain, not in the preferences.
        var apiKey = ""
        /// The Hugging Face token for private and gated models, given to the
        /// engine in `HF_TOKEN`. Blank leaves the engine with the token that
        /// `hf auth login` saved. Kept in the keychain.
        var huggingFaceToken = ""

        // Memory and context.
        var maxMemory = ""
        var maxContext = ""
        var pleMemory = ""
        var expertMemory = ""
        var sparseKVMemory = ""
        var kvFormat: KVFormat = .standard
        var stateFormat: StateFormat = .standard
        var cachedStates: CachedStates = .standard
        var activations: Activations = .standard
        var idleRelease = ""
        var disableANE = false
        var recalibrateANE = false

        // SSD cache.
        var maxCacheDisk = ""
        var maxCacheDiskWrites = ""
        var persistentCache = false
        var cacheDirectory = ""

        // API.
        var servedModelNames = ""
        var announceServedName = false
        var reasoningEffort: ReasoningEffort = .modelDefault
        var reasoningScope: ReasoningScope = .requestsWithoutOne
        var thinkingTokenBudget = ""
        var thinkingEndText = ""
        /// A Jinja chat template that replaces the model's own: `--chat-template-file`.
        var chatTemplatePath = ""

        // Requests.
        var maxRequestSize = ""
        var maxImagePixels = ""
        var requestTimeout = ""
        var queueSize = ""
        var maxConcurrentRequests = ""
        var decodeShare = ""
        var samplingTemperature = ""
        var samplingTopP = ""
        var samplingTopK = ""
        var samplingMinP = ""
        var samplingPresencePenalty = ""
        var samplingFrequencyPenalty = ""
        var samplingRepetitionPenalty = ""
        var verifyRows: VerifyRows = .standard
        var allowIdleSleep = false

        // Diagnostics and application behavior.
        var logPath = "~/Library/Logs/llmenubar/engine.log"
        var logMaxSizeMB = 10
        /// Extra environment for Splash, one `NAME=VALUE` per line.
        var environment = ""
        /// Has the engine record a crash trace when it fails: gives it
        /// `SPLASH_CRASH_TRACE=1`.
        var crashTrace = false
        var launchAtLogin = false
    }

    // MARK: Configuration access

    /// The only property read individually outside a snapshot: the menu-bar
    /// "Open Log in Console" action and the failure-reason tail both need it
    /// without taking a full copy of the configuration.
    var logPath: String { values.logPath }

    /// Return an immutable value snapshot suitable for a Settings draft or a
    /// process launch. A value snapshot prevents half-edited settings from
    /// reaching a child process.
    func snapshot() -> Config {
        values
    }

    /// Replace the active configuration with a validated Settings snapshot.
    func replace(with config: Config) {
        values = config.normalized()
    }

    // MARK: Persistence

    private static let configKey = "llmenubar.config"
    private static let performanceDisplayKey = "llmenubar.showPerformanceInMenuBar"
    private static let keepAwakeKey = "llmenubar.keepAwakeWhileServerRuns"
    private static let confirmQuitKey = "llmenubar.confirmQuitWhileServerActive"
    private static let autoRestartKey = "llmenubar.autoRestartServer"
    private static let recentSelectionsKey = "llmenubar.recentSelections"
    private static let familyMemoryKey = "llmenubar.modelFamilyMemory"

    var needsInitialSetup: Bool {
        guard defaults.object(forKey: Self.configKey) != nil else { return true }
        return !values.hasSplash || !values.hasModel
    }

    private func loadConfig() {
        if let data = defaults.data(forKey: Self.configKey),
           let config = try? JSONDecoder().decode(Config.self, from: data) {
            values = config.normalized()
            loadSecrets()
            // The toggle shows what the system says, not what was saved: the
            // item can be removed in System Settings behind the app's back.
            values.launchAtLogin = Self.isLoginItemActive
            seedRecentSelectionsFromConfiguration()
            updateFamilyMemory { $0.seed(values) }
        }
    }

    func completeInitialSetup(splashPath: String, model: InitialModel, modelCacheDirectory: String = "",
                              huggingFaceToken: String = "") {
        var configured = values
        configured.splashPath = splashPath
        configured.modelCacheDirectory = modelCacheDirectory
        configured.huggingFaceToken = huggingFaceToken
        switch model {
        case .huggingFace(let id):
            configured.modelSource = .huggingFace
            configured.huggingFaceModel = id
        case .local(let path):
            configured.modelSource = .local
            configured.modelPath = path
        }
        values = configured.normalized()
        persistConfig()
        let applied = values
        updateRecentSelections { recents in
            for entry in RecentSelections.entries(in: applied) {
                recents.record(
                    entry.path, for: entry.field, family: entry.family,
                    fileKey: Self.fileKey(for: entry.field)
                )
            }
        }
        updateFamilyMemory { $0.record(applied) }
    }

    /// The first thing a new installation asks for.
    enum InitialModel: Equatable {
        case huggingFace(String)
        case local(String)
    }

    /// The secrets come from the keychain. A value an older build left in the
    /// preferences is not used.
    private func loadSecrets() {
        values.apiKey = ""
        values.huggingFaceToken = ""
        unreadableSecrets = []
        for secret in Secret.allCases {
            do {
                let value = try secrets.read(secret)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                switch secret {
                case .apiKey: values.apiKey = value
                case .huggingFaceToken: values.huggingFaceToken = value
                }
            } catch {
                unreadableSecrets.insert(secret)
                os_log(.error, log: log, "reading %{public}s failed: %{public}@",
                       secret.rawValue, error.localizedDescription)
            }
        }
    }

    /// Writes the preferences without the secrets and the secrets to the
    /// keychain. Returns what went wrong with the keychain, if anything.
    @discardableResult
    private func persistConfig() -> String? {
        var stored = values
        stored.apiKey = ""
        stored.huggingFaceToken = ""
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.configKey)
        }
        var failures: [String] = []
        for secret in Secret.allCases {
            let value: String
            let name: String
            switch secret {
            case .apiKey: value = values.apiKey; name = "The API key"
            case .huggingFaceToken: value = values.huggingFaceToken; name = "The Hugging Face token"
            }
            if value.isEmpty, unreadableSecrets.contains(secret) { continue }
            do {
                try secrets.write(value, for: secret)
                unreadableSecrets.remove(secret)
            } catch {
                os_log(.error, log: log, "writing %{public}s failed: %{public}@",
                       secret.rawValue, error.localizedDescription)
                failures.append("\(name) was not saved: \(error.localizedDescription).")
            }
        }
        return failures.isEmpty ? nil : failures.joined(separator: " ")
    }

    // MARK: App-only preferences

    /// Why a launch-at-login request did not take full effect. Returned by
    /// `save()` so Settings can say so: the read-back below can flip the toggle
    /// back off, and a toggle that silently undoes itself reads as a bug.
    enum LoginItemWarning {
        case enableFailed(String)
        case disableFailed(String)
        case approvalRequired

        var message: String {
            switch self {
            case .enableFailed(let reason):
                return "Launch at login could not be enabled — \(reason)"
            case .disableFailed(let reason):
                return "Launch at login could not be disabled — \(reason)"
            case .approvalRequired:
                return "Launch at login needs approval in System Settings › General › Login Items."
            }
        }
    }

    struct LoginItemUpdate {
        let isEnabled: Bool
        let warning: String?
    }

    /// Apply this app-only setting immediately without sending the server
    /// configuration through its staged Apply & Restart path.
    func setLaunchAtLogin(_ requested: Bool) -> LoginItemUpdate {
        values.launchAtLogin = requested
        let warning = applyLoginItem()?.message
        persistConfig()
        return LoginItemUpdate(isEnabled: values.launchAtLogin, warning: warning)
    }

    /// Persist this app-only display preference immediately. It does not alter
    /// Splash's command line and must not enter the Apply & Restart path.
    func setShowsPerformanceInMenuBar(_ requested: Bool) {
        showsPerformanceInMenuBar = requested
        defaults.set(requested, forKey: Self.performanceDisplayKey)
    }

    /// Persist the keep-awake preference immediately, on the same terms: it is
    /// an app behavior, not part of Splash's command line.
    func setKeepsAwakeWhileRunning(_ requested: Bool) {
        keepsAwakeWhileRunning = requested
        defaults.set(requested, forKey: Self.keepAwakeKey)
    }

    /// Persist the quit-confirmation preference immediately, on the same terms.
    func setConfirmQuitWhileServerActive(_ requested: Bool) {
        confirmQuitWhileServerActive = requested
        defaults.set(requested, forKey: Self.confirmQuitKey)
    }

    /// Persist the auto-restart preference immediately, on the same terms.
    func setAutoRestartServer(_ requested: Bool) {
        autoRestartServer = requested
        defaults.set(requested, forKey: Self.autoRestartKey)
    }

    // MARK: Recent selections

    /// How two spellings of one path are told apart: `~/x` and `/Users/me/x`
    /// are one file.
    static func recentFileKey(_ path: String) -> String {
        (PathText.expandingTilde(path) as NSString).standardizingPath
    }

    /// A Hugging Face model ID is text; everything else remembered is a path.
    static func fileKey(for field: RecentSelections.Field) -> (String) -> String {
        field == .huggingFaceModel ? { $0 } : recentFileKey
    }

    /// Whether a remembered path can still be used.
    enum PathAvailability: Equatable {
        case available
        /// Gone from a volume that is mounted: the entry is dropped.
        case missing
        /// On a volume that is not mounted: the entry stays, disabled.
        case unavailable
    }

    static func recentPathAvailability(_ path: String) -> PathAvailability {
        let resolved = PathText.expandingTilde(path)
        if FileManager.default.fileExists(atPath: resolved) { return .available }
        // A path under /Volumes whose volume is not mounted may come back.
        let components = (resolved as NSString).pathComponents
        if components.count > 2, components[1] == "Volumes" {
            let volume = "/Volumes/" + components[2]
            if !FileManager.default.fileExists(atPath: volume) { return .unavailable }
        }
        return .missing
    }

    /// Remember the paths an Apply changed, for the rows' recent menus. Like
    /// the preferences above this is app-only state: it never enters the
    /// applied configuration or the launch command, and nothing is
    /// remembered until a configuration is applied.
    ///
    /// Entries whose file is gone from a mounted volume are dropped at the
    /// same time, so a history the user has stopped curating does not keep
    /// them. One on an unmounted volume stays.
    func recordAppliedSelections(previous: Config) {
        let applied = values
        updateRecentSelections { recents in
            recents.recordApply(
                from: RecentSelections.entries(in: previous),
                to: RecentSelections.entries(in: applied),
                fileKey: Self.fileKey(for:)
            )
            recents.prune { field, path in
                field != .huggingFaceModel && Self.recentPathAvailability(path) == .missing
            }
        }
        updateFamilyMemory { $0.record(applied) }
    }

    /// Forget one row's history. This takes effect at once, like Clear Menu
    /// in a document app's Open Recent: it changes no setting, so there is
    /// nothing for Apply to confirm.
    func clearRecentSelections(field: RecentSelections.Field, family: String? = nil) {
        updateRecentSelections { $0.clear(field, family: family) }
    }

    /// What switching `current` to `family` would put back.
    func familyRestoration(for family: String, current: Config) -> ModelFamilyMemory.Restoration? {
        familyMemory.restoration(for: family, current: current)
    }

    private func updateFamilyMemory(_ change: (inout ModelFamilyMemory) -> Void) {
        var memory = familyMemory
        change(&memory)
        guard memory != familyMemory else { return }
        familyMemory = memory
        if let data = try? JSONEncoder().encode(memory) {
            defaults.set(data, forKey: Self.familyMemoryKey)
        }
    }

    private func seedRecentSelectionsFromConfiguration() {
        let current = values
        updateRecentSelections { recents in
            for entry in RecentSelections.entries(in: current) {
                recents.seed(entry.path, for: entry.field, family: entry.family, fileKey: Self.fileKey(for: entry.field))
            }
        }
    }

    /// Persist the history only when a change actually altered it.
    private func updateRecentSelections(_ change: (inout RecentSelections) -> Void) {
        var recents = recentSelections
        change(&recents)
        guard recents != recentSelections else { return }
        recentSelections = recents
        if let data = try? JSONEncoder().encode(recentSelections) {
            defaults.set(data, forKey: Self.recentSelectionsKey)
        }
    }

    // MARK: Login item

    /// Persist the current configuration and apply launch-at-login. Login-item
    /// state is read back because unsigned/debug builds can reject registration.
    /// Returns what the user should be told, if anything: a login item that did
    /// not take, or a secret the keychain would not keep.
    @discardableResult
    func save() -> String? {
        let warning = applyLoginItem()?.message
        let keychain = persistConfig()
        let messages = [warning, keychain].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: " ")
    }

    /// Whether the app is currently registered as a login item — including the
    /// registered-but-awaiting-approval state, since re-registering does not
    /// advance it.
    private static var isLoginItemActive: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    /// Register or unregister only when the live login-item state differs from
    /// the requested one. The calls are idempotent, but every Apply persists the
    /// whole configuration, and an Apply that never touched the toggle has no
    /// reason to make an SMAppService call at all.
    private func applyLoginItem() -> LoginItemWarning? {
        let requested = values.launchAtLogin
        var failure: String?
        if requested != Self.isLoginItemActive {
            do {
                if requested {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                failure = error.localizedDescription
                os_log(.error, log: log, "login item %{public}s failed: %{public}@",
                       requested ? "enable" : "disable", error.localizedDescription)
            }
        }

        let status = SMAppService.mainApp.status
        values.launchAtLogin = (status == .enabled || status == .requiresApproval)

        // Report only on an end state that differs from what was asked for; a
        // call that threw but landed in the requested state needs no message.
        if values.launchAtLogin != requested {
            let reason = failure ?? "the system reports it as \(Self.describe(status))"
            return requested ? .enableFailed(reason) : .disableFailed(reason)
        }
        if requested && status == .requiresApproval { return .approvalRequired }
        return nil
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "not registered"
        case .enabled: return "enabled"
        case .requiresApproval: return "awaiting approval"
        case .notFound: return "not found"
        @unknown default: return "in an unknown state"
        }
    }
}

// MARK: - Limits and normalization

enum ConfigurationLimits {
    /// Ports below 1024 are privileged: binding one needs root, and the app
    /// launches Splash as a plain child of itself, so the whole range is
    /// unreachable. Offering it in Settings only buys an error in the server
    /// log, well after the user has left the field that caused it.
    static let minPort = 1_024
    static let maxPort = 65_535
    static let minLogSizeMB = 5
    static let maxLogSizeMB = 128
}

extension ServerConfiguration.Config {
    var hasSplash: Bool { !splashPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var hasModel: Bool {
        switch modelSource {
        case .huggingFace: return !huggingFaceModel.isEmpty
        case .local: return !modelPath.isEmpty
        }
    }

    /// Trim text and give every stored path one spelling. Applied to whatever
    /// is loaded or applied, so a hand-edited blob and a Settings draft are
    /// held to the same form.
    func normalized() -> Self {
        var config = self
        func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        func path(_ text: String) -> String {
            let value = trimmed(text)
            return value.isEmpty ? value : PathText.storingAbsolute(value)
        }
        config.splashPath = path(splashPath)
        config.huggingFaceModel = trimmed(huggingFaceModel)
        config.modelPath = path(modelPath)
        config.localModelName = trimmed(localModelName)
        config.apiKey = trimmed(apiKey)
        config.huggingFaceToken = trimmed(huggingFaceToken)
        config.environment = environment
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        config.visionProjectorPath = path(visionProjectorPath)
        let draft = trimmed(draftModel)
        config.draftModel = draft.hasPrefix("/") || draft.hasPrefix("~") ? path(draft) : draft
        config.revision = trimmed(revision)
        config.host = trimmed(host)
        config.allowedHosts = trimmed(allowedHosts)
        config.allowedOrigins = trimmed(allowedOrigins)
        config.maxMemory = trimmed(maxMemory)
        config.maxContext = trimmed(maxContext)
        config.pleMemory = trimmed(pleMemory)
        config.expertMemory = trimmed(expertMemory)
        config.sparseKVMemory = trimmed(sparseKVMemory)
        config.idleRelease = trimmed(idleRelease)
        config.maxCacheDisk = trimmed(maxCacheDisk)
        config.maxCacheDiskWrites = trimmed(maxCacheDiskWrites)
        config.cacheDirectory = path(cacheDirectory)
        config.chatTemplatePath = path(chatTemplatePath)
        config.modelCacheDirectory = path(modelCacheDirectory)
        config.servedModelNames = trimmed(servedModelNames)
        config.thinkingTokenBudget = trimmed(thinkingTokenBudget)
        config.thinkingEndText = trimmed(thinkingEndText)
        config.maxRequestSize = trimmed(maxRequestSize)
        config.maxImagePixels = trimmed(maxImagePixels)
        config.requestTimeout = trimmed(requestTimeout)
        config.queueSize = trimmed(queueSize)
        config.maxConcurrentRequests = trimmed(maxConcurrentRequests)
        config.samplingTemperature = trimmed(samplingTemperature)
        config.samplingTopP = trimmed(samplingTopP)
        config.samplingTopK = trimmed(samplingTopK)
        config.samplingMinP = trimmed(samplingMinP)
        config.samplingPresencePenalty = trimmed(samplingPresencePenalty)
        config.samplingFrequencyPenalty = trimmed(samplingFrequencyPenalty)
        config.samplingRepetitionPenalty = trimmed(samplingRepetitionPenalty)
        config.decodeShare = trimmed(decodeShare)
        config.logPath = path(logPath)
        return config
    }

    /// What `--model` is given: the Hugging Face ID, or the name the API will
    /// report for local files.
    var modelArgument: String {
        switch modelSource {
        case .huggingFace: return huggingFaceModel
        case .local: return localModelName.isEmpty
            ? SplashModel.localAPIName(forPath: modelPath)
            : localModelName
        }
    }
}

// MARK: - Lenient Config decoding

private extension KeyedDecodingContainer {
    /// The stored value, or `fallback` when the key is missing or no longer
    /// reads as the type it had.
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

extension ServerConfiguration.Config {
    /// Missing keys from older builds fall back to the current defaults, and
    /// so does a value that no longer decodes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        splashPath = c.value(.splashPath, d.splashPath)
        modelSource = c.value(.modelSource, d.modelSource)
        huggingFaceModel = c.value(.huggingFaceModel, d.huggingFaceModel)
        modelPath = c.value(.modelPath, d.modelPath)
        localModelName = c.value(.localModelName, d.localModelName)
        visionProjectorPath = c.value(.visionProjectorPath, d.visionProjectorPath)
        draftModel = c.value(.draftModel, d.draftModel)
        revision = c.value(.revision, d.revision)
        languageOnly = c.value(.languageOnly, d.languageOnly)
        offline = c.value(.offline, d.offline)
        modelCacheDirectory = c.value(.modelCacheDirectory, d.modelCacheDirectory)
        host = c.value(.host, d.host)
        port = c.value(.port, d.port)
        allowedHosts = c.value(.allowedHosts, d.allowedHosts)
        allowedOrigins = c.value(.allowedOrigins, d.allowedOrigins)
        chatPageEnabled = c.value(.chatPageEnabled, d.chatPageEnabled)
        apiKey = c.value(.apiKey, d.apiKey)
        huggingFaceToken = c.value(.huggingFaceToken, d.huggingFaceToken)
        maxMemory = c.value(.maxMemory, d.maxMemory)
        maxContext = c.value(.maxContext, d.maxContext)
        pleMemory = c.value(.pleMemory, d.pleMemory)
        expertMemory = c.value(.expertMemory, d.expertMemory)
        sparseKVMemory = c.value(.sparseKVMemory, d.sparseKVMemory)
        kvFormat = c.value(.kvFormat, d.kvFormat)
        stateFormat = c.value(.stateFormat, d.stateFormat)
        cachedStates = c.value(.cachedStates, d.cachedStates)
        activations = c.value(.activations, d.activations)
        idleRelease = c.value(.idleRelease, d.idleRelease)
        disableANE = c.value(.disableANE, d.disableANE)
        recalibrateANE = c.value(.recalibrateANE, d.recalibrateANE)
        maxCacheDisk = c.value(.maxCacheDisk, d.maxCacheDisk)
        maxCacheDiskWrites = c.value(.maxCacheDiskWrites, d.maxCacheDiskWrites)
        persistentCache = c.value(.persistentCache, d.persistentCache)
        cacheDirectory = c.value(.cacheDirectory, d.cacheDirectory)
        servedModelNames = c.value(.servedModelNames, d.servedModelNames)
        announceServedName = c.value(.announceServedName, d.announceServedName)
        reasoningEffort = c.value(.reasoningEffort, d.reasoningEffort)
        reasoningScope = c.value(.reasoningScope, d.reasoningScope)
        thinkingTokenBudget = c.value(.thinkingTokenBudget, d.thinkingTokenBudget)
        thinkingEndText = c.value(.thinkingEndText, d.thinkingEndText)
        chatTemplatePath = c.value(.chatTemplatePath, d.chatTemplatePath)
        maxRequestSize = c.value(.maxRequestSize, d.maxRequestSize)
        maxImagePixels = c.value(.maxImagePixels, d.maxImagePixels)
        requestTimeout = c.value(.requestTimeout, d.requestTimeout)
        queueSize = c.value(.queueSize, d.queueSize)
        maxConcurrentRequests = c.value(.maxConcurrentRequests, d.maxConcurrentRequests)
        samplingTemperature = c.value(.samplingTemperature, d.samplingTemperature)
        samplingTopP = c.value(.samplingTopP, d.samplingTopP)
        samplingTopK = c.value(.samplingTopK, d.samplingTopK)
        samplingMinP = c.value(.samplingMinP, d.samplingMinP)
        samplingPresencePenalty = c.value(.samplingPresencePenalty, d.samplingPresencePenalty)
        samplingFrequencyPenalty = c.value(.samplingFrequencyPenalty, d.samplingFrequencyPenalty)
        samplingRepetitionPenalty = c.value(.samplingRepetitionPenalty, d.samplingRepetitionPenalty)
        decodeShare = c.value(.decodeShare, d.decodeShare)
        verifyRows = c.value(.verifyRows, d.verifyRows)
        allowIdleSleep = c.value(.allowIdleSleep, d.allowIdleSleep)
        logPath = c.value(.logPath, d.logPath)
        // A saved size outside today's range (the limits were once 1 to 10,240)
        // is brought into it: rotation copies up to this many bytes.
        logMaxSizeMB = min(max(c.value(.logMaxSizeMB, d.logMaxSizeMB),
                               ConfigurationLimits.minLogSizeMB), ConfigurationLimits.maxLogSizeMB)
        environment = c.value(.environment, d.environment)
        crashTrace = c.value(.crashTrace, d.crashTrace)
        launchAtLogin = c.value(.launchAtLogin, d.launchAtLogin)
    }
}
