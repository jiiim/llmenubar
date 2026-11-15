// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation

/// Which family a model belongs to, as far as the app can tell without
/// running Splash. The key only files preferences: it is never shown, never
/// sent to Splash, and never used as a name.
///
/// A projector or a draft works with one family's models. Every quantization
/// of a model is one family, so the key drops what tells quantizations apart.
enum ModelFamily {
    /// The family of the model `config` is set to serve, or nil while none is
    /// named yet.
    static func key(of config: ServerConfiguration.Config) -> String? {
        switch config.modelSource {
        case .huggingFace: return key(huggingFaceModel: config.huggingFaceModel)
        case .local: return key(localPath: config.modelPath)
        }
    }

    /// `unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M` -> `unsloth/qwen3.8-27b-gguf`.
    /// Nil until the text is a complete model ID.
    static func key(huggingFaceModel text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SplashModel.isModelID(trimmed) else { return nil }
        let repository = trimmed.split(separator: ":", maxSplits: 1).first.map(String.init) ?? trimmed
        return repository.lowercased()
    }

    /// `/m/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf` ->
    /// `qwen3.8-flash-next`: the file's or folder's own name without its
    /// extension, shard number, quantization or `-GGUF`.
    static func key(localPath path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var name = PathText.fileName(of: PathText.expandingTilde(trimmed))
        if name.lowercased().hasSuffix(".gguf") { name.removeLast(5) }
        // Shard `-00001-of-00004`, then any run of quantization and format
        // tags: `-UD-Q4_K_XL`, `-Q8_0`, `-IQ3_XXS`, `-BF16`, `-4bit`, `-GGUF`.
        name = name.replacingOccurrences(
            of: #"-\d{3,6}-of-\d{3,6}$"#, with: "", options: [.regularExpression, .caseInsensitive]
        )
        let tag = #"(?:[-_.]UD)?[-_.](?:I?Q\d[A-Z0-9_]*|BF16|F16|F32|MXFP4|NVFP4|\d{1,2}bit|GGUF)$"#
        while let range = name.range(of: tag, options: [.regularExpression, .caseInsensitive]) {
            name.removeSubrange(range)
        }
        let key = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-_. "))
        return key.isEmpty ? nil : key
    }
}

/// The files each family was last applied with: its vision projector and its
/// draft, as paths or, for a Hugging Face model, a repository. Switching to a
/// family puts these back, so a projector never outlives the model it was
/// made for.
struct ModelFamilyMemory: Codable, Equatable {
    struct Companions: Codable, Equatable {
        var visionProjector = ""
        var draft = ""
    }

    private var byFamily: [String: Companions] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey { case byFamily }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        byFamily = try container.decodeIfPresent([String: Companions].self, forKey: .byFamily) ?? [:]
    }

    func companions(for family: String) -> Companions? { byFamily[family] }

    private static func companions(in config: ServerConfiguration.Config) -> Companions {
        Companions(
            // A Hugging Face model has no projector file.
            visionProjector: config.modelSource == .local
                ? config.visionProjectorPath.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            draft: config.draftModel.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Remember what an applied configuration pairs its model's family with.
    mutating func record(_ config: ServerConfiguration.Config) {
        guard let family = ModelFamily.key(of: config) else { return }
        byFamily[family] = Self.companions(in: config)
    }

    /// Remember a configuration that predates this memory, without replacing
    /// what is already known about its family.
    mutating func seed(_ config: ServerConfiguration.Config) {
        guard let family = ModelFamily.key(of: config), byFamily[family] == nil else { return }
        byFamily[family] = Self.companions(in: config)
    }

    /// What switching `current` to `family` changes: the family's last files,
    /// or none for a family never applied. Nil when nothing would change.
    struct Restoration: Equatable {
        let visionProjector: String
        let draft: String
        /// What to tell the user happened.
        let message: String
    }

    func restoration(for family: String, current config: ServerConfiguration.Config) -> Restoration? {
        let target = byFamily[family] ?? Companions()
        let oldProjector = config.visionProjectorPath
        let oldDraft = config.draftModel
        guard target.visionProjector != oldProjector || target.draft != oldDraft else { return nil }

        var restored: [String] = []
        var cleared: [String] = []
        for (name, old, new) in [
            ("vision projector", oldProjector, target.visionProjector),
            ("draft", oldDraft, target.draft),
        ] where old != new {
            if new.isEmpty { cleared.append(name) } else { restored.append(name) }
        }
        var sentences: [String] = []
        if !restored.isEmpty {
            sentences.append("Restored the \(restored.joined(separator: " and ")) last used with this model.")
        }
        if !cleared.isEmpty {
            let verb = cleared.count == 1 ? "belongs" : "belong"
            sentences.append("Cleared the \(cleared.joined(separator: " and ")), which \(verb) to the previous model.")
        }
        return Restoration(
            visionProjector: target.visionProjector,
            draft: target.draft,
            message: sentences.joined(separator: " ")
        )
    }
}
