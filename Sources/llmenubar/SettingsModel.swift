// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation
import Combine

enum SettingsPane: String, CaseIterable, Hashable, Identifiable {
    case general
    case model
    case server
    case memory
    case cache
    case api
    case requests
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .model: return "Model"
        case .server: return "Server"
        case .memory: return "Memory"
        case .cache: return "SSD Cache"
        case .api: return "API"
        case .requests: return "Requests"
        case .diagnostics: return "Diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .model: return "cube"
        case .server: return "network"
        case .memory: return "memorychip"
        case .cache: return "internaldrive"
        case .api: return "arrow.left.arrow.right"
        case .requests: return "tray.full"
        case .diagnostics: return "stethoscope"
        }
    }

    /// The pane that renders a field's row. Apply switches to this pane when a
    /// field refuses the draft, so a message is never attached to a control on
    /// a pane the user cannot see. Exhaustive on purpose: a new field has to
    /// say where it is shown rather than silently landing on General.
    static func containing(_ field: ServerConfiguration.Config.Field) -> SettingsPane {
        switch field {
        case .splashPath:
            return .general
        case .huggingFaceModel, .modelPath, .visionProjectorPath, .draftModel, .revision, .draftRevision,
             .modelCacheDirectory, .huggingFaceToken, .chatTemplatePath:
            return .model
        case .host, .port, .allowedHosts, .allowedOrigins:
            return .server
        case .maxMemory, .maxContext, .pleMemory, .expertMemory, .sparseKVMemory, .idleRelease, .weights, .activations,
             .cachedStates, .recalibrateANE:
            return .memory
        case .maxCacheDisk, .maxCacheDiskWrites, .cacheDirectory:
            return .cache
        case .apiKey, .localModelName, .servedModelNames:
            return .api
        case .reasoningEffort, .thinkingTokenBudget, .thinkingEndText,
             .maxRequestSize, .maxImagePixels, .requestTimeout, .shutdownTimeout, .queueSize, .maxConcurrentRequests, .decodeShare,
             .samplingTemperature, .samplingTopP, .samplingTopK, .samplingMinP,
             .samplingPresencePenalty, .samplingFrequencyPenalty, .samplingRepetitionPenalty:
            return .requests
        case .environment:
            return .general
        case .logPath, .logMaxSizeMB:
            return .diagnostics
        }
    }
}

/// The inputs of `SplashDerivedState`: the draft fields whose files get read.
/// Reading them touches the disk and runs `splash`, so it happens only when one
/// of these changes.
struct SettingsDerivedInputs: Equatable, Hashable {
    let splashPath: String
    let modelSource: ServerConfiguration.ModelSource
    let modelPath: String
    let visionProjectorPath: String
    let languageOnly: Bool
    let draftModel: String
    let chatTemplatePath: String

    init(_ config: ServerConfiguration.Config) {
        splashPath = config.splashPath
        modelSource = config.modelSource
        modelPath = config.modelPath
        visionProjectorPath = config.visionProjectorPath
        languageOnly = config.languageOnly
        draftModel = config.draftModel
        chatTemplatePath = config.chatTemplatePath
    }
}

/// A path row's target: which setting a chosen path is written to.
enum SettingsPathField: Hashable {
    case splash
    case model
    case visionProjector
    case draft
    case chatTemplate
    case cacheDirectory
    case logDirectory

    var choosesDirectory: Bool {
        switch self {
        case .draft, .cacheDirectory, .logDirectory: return true
        case .splash, .model, .visionProjector, .chatTemplate: return false
        }
    }

    /// The model row takes either: a GGUF file or a folder.
    var choosesFileOrDirectory: Bool { self == .model }

    /// Whether the row's recent files belong to the model family the draft
    /// names: a projector or draft is made for one family's models.
    var isFamilySpecific: Bool { self == .visionProjector || self == .draft }

    var recentField: RecentSelections.Field? {
        switch self {
        case .splash: return .splash
        case .model: return .model
        case .visionProjector: return .visionProjector
        case .draft: return .draft
        case .chatTemplate, .cacheDirectory, .logDirectory: return nil
        }
    }
}

/// Makes the keys the Generate button offers.
enum APIKeyGenerator {
    /// `llm-` and 32 random hexadecimal digits: visible ASCII, easy to paste
    /// into a client, and 128 bits.
    static func make() -> String {
        "llm-" + (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }
}

extension ServerConfiguration.Config {
    /// The configuration with every Splash option back at its default. What
    /// identifies the installation and its model stays: which Splash, which
    /// model and the name it is served as, the log and the environment
    /// Splash runs in, and the login-item setting.
    func restoringDefaults() -> Self {
        var restored = Self()
        restored.splashPath = splashPath
        restored.modelSource = modelSource
        restored.huggingFaceModel = huggingFaceModel
        restored.modelCacheDirectory = modelCacheDirectory
        restored.modelPath = modelPath
        restored.localModelName = localModelName
        restored.logPath = logPath
        restored.logMaxSizeMB = logMaxSizeMB
        restored.environment = environment
        restored.crashTrace = crashTrace
        // An account credential, not an engine option, and Hugging Face shows
        // a token only once, so clearing it here could not be undone.
        restored.huggingFaceToken = huggingFaceToken
        restored.launchAtLogin = launchAtLogin
        return restored
    }
}

/// Persist the last selected pane across Settings scene destruction.
@MainActor
final class SettingsPaneSelection: ObservableObject {
    static let key = "llmenubar.settingsPane"
    private let defaults: UserDefaults
    @Published var rawValue: String {
        didSet { defaults.set(rawValue, forKey: Self.key) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: Self.key) ?? ""
        rawValue = SettingsPane(rawValue: saved)?.rawValue ?? SettingsPane.general.rawValue
    }
}
