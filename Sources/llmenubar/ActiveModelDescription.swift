// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation

/// What the status menu says about the model the app is configured to run.
/// It describes the configuration, not anything Splash reported.
struct ActiveModelInfo: Equatable {
    /// Nothing configured yet; the status menu hides the row.
    static let empty = ActiveModelInfo(title: "", names: [], subtitle: nil, toolTip: nil)

    /// The model ID, or the name of the local file or folder.
    let title: String
    /// Every name the API accepts for the model, in the order `/v1/models`
    /// lists them.
    let names: [String]
    /// Where the model comes from, or what is wrong with it.
    let subtitle: String?
    /// The full path of local files.
    let toolTip: String?

    static func describing(_ config: ServerConfiguration.Config) -> ActiveModelInfo {
        guard config.hasModel else { return .empty }
        let names = servedNames(config)
        switch config.modelSource {
        case .huggingFace:
            return ActiveModelInfo(
                title: config.huggingFaceModel,
                names: names,
                subtitle: "Hugging Face",
                toolTip: nil
            )
        case .local:
            let resolved = PathText.expandingTilde(config.modelPath)
            let exists = FileManager.default.fileExists(atPath: resolved)
            return ActiveModelInfo(
                title: PathText.fileName(of: config.modelPath),
                names: names,
                subtitle: exists ? "On this Mac" : "Not found",
                toolTip: exists ? resolved : "\(resolved) — not found"
            )
        }
    }

    /// The names `/v1/models` lists: the model's own ID first, then the other
    /// names; with "Answer as the first other name" on, that first other name
    /// comes first, because it is the one responses carry.
    static func servedNames(_ config: ServerConfiguration.Config) -> [String] {
        let own = config.modelArgument
        let others = SplashOptionValues.items(config.servedModelNames)
        var ordered = [own] + others
        if config.announceServedName, let announced = others.first {
            ordered = [announced, own] + others.dropFirst()
        }
        var seen = Set<String>()
        return ordered.filter { seen.insert($0).inserted }
    }
}
