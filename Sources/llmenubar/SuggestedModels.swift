// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation
import SwiftUI

/// Models offered by name on the setup window: for each model line, the best
/// known one for each memory size Macs come in, up to the memory this Mac
/// has.
///
/// The list is short on purpose: the Qwen and Inkling models Splash serves
/// best, as Unsloth's GGUFs. Anything else is typed in.
struct SuggestedModel: Equatable, Identifiable, Sendable {
    /// The menu section: the model line, whatever its version.
    let group: String
    let family: String
    let repository: String
    let variant: String
    /// The GGUF's size on disk, in GiB.
    let sizeGiB: Double
    /// The memory size, in GB, this is the best known model for. A Mac with
    /// more memory is offered it too, beside the better ones its own size has.
    let memoryTierGiB: Int
    /// The first Splash release that serves this model; the suggestion is
    /// hidden for an older or unknown engine.
    var minimumSplash: SplashVersion?

    var id: String { modelID }

    /// What `--model` takes: `owner/repo:VARIANT`.
    var modelID: String { "\(repository):\(variant)" }

    /// `UD-Q4_K_XL, 104 GB`.
    var detail: String { "\(variant), \(Int(sizeGiB.rounded())) GB" }

    /// `128 GB Mac: Qwen3.8 Flash Next, UD-Q4_K_XL, 104 GB`.
    var menuTitle: String { "\(memoryTierGiB) GB Mac: \(family), \(detail)" }

    static let qwen = "Qwen"
    static let inkling = "Inkling (text only)"

    static let flashNext = "Qwen3.8 Flash Next"
    static let dense27B = "Qwen3.8 27B"
    static let inklingMini = "Inkling-2-Mini"
    /// Splash 1.7.2 added Inkling-2-Mini.
    static let inklingRelease = SplashVersion(1, 7, 2)

    // Sizes are the sum of each variant's files on Hugging Face. Each model
    // leaves its tier at least a tenth over its size for the context and
    // macOS. Splash refuses a GGUF that is mostly unquantized, so BF16 is
    // never offered and the 256 GB model is also the best for 512 GB. Each
    // group has one model for each of its tiers; Inkling-2-Mini's largest
    // GGUF, UD-Q8_K_XL, is also the best for every Mac above 48 GB. Splash
    // suggests Inkling-2-Mini from 36 GB and has not measured it on 24 GB, so
    // its first tier is 36 GB.
    static let all: [SuggestedModel] = [
        .init(group: qwen, family: flashNext, repository: "unsloth/Qwen3.8-Flash-Next-GGUF", variant: "Q8_0", sizeGiB: 185.6, memoryTierGiB: 256),
        .init(group: qwen, family: flashNext, repository: "unsloth/Qwen3.8-Flash-Next-GGUF", variant: "UD-Q6_K_XL", sizeGiB: 157.5, memoryTierGiB: 192),
        .init(group: qwen, family: flashNext, repository: "unsloth/Qwen3.8-Flash-Next-GGUF", variant: "UD-Q4_K_XL", sizeGiB: 103.7, memoryTierGiB: 128),
        .init(group: qwen, family: flashNext, repository: "unsloth/Qwen3.8-Flash-Next-GGUF", variant: "UD-IQ3_XXS", sizeGiB: 77.9, memoryTierGiB: 96),
        .init(group: qwen, family: dense27B, repository: "unsloth/Qwen3.8-27B-GGUF", variant: "UD-Q8_K_XL", sizeGiB: 29.3, memoryTierGiB: 64),
        .init(group: qwen, family: dense27B, repository: "unsloth/Qwen3.8-27B-GGUF", variant: "UD-Q6_K", sizeGiB: 20.5, memoryTierGiB: 48),
        .init(group: qwen, family: dense27B, repository: "unsloth/Qwen3.8-27B-GGUF", variant: "UD-Q4_K_M", sizeGiB: 15.4, memoryTierGiB: 32),
        .init(group: qwen, family: dense27B, repository: "unsloth/Qwen3.8-27B-GGUF", variant: "UD-IQ3_XXS", sizeGiB: 10.2, memoryTierGiB: 24),
        .init(group: inkling, family: inklingMini, repository: "unsloth/Inkling-2-Mini-GGUF", variant: "UD-Q8_K_XL", sizeGiB: 21.3, memoryTierGiB: 48, minimumSplash: inklingRelease),
        .init(group: inkling, family: inklingMini, repository: "unsloth/Inkling-2-Mini-GGUF", variant: "UD-Q4_K_M", sizeGiB: 15.47, memoryTierGiB: 36, minimumSplash: inklingRelease),
    ]

    /// The suggestions for a Mac with `physicalMemory` bytes and the engine
    /// `build`, the one for its own memory size first. A model the engine is
    /// too old for, or may be too old for, is left out.
    static func available(
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
        build: SplashBuild
    ) -> [SuggestedModel] {
        let gibibytes = Double(physicalMemory) / Double(1 << 30)
        return all.filter { model in
            Double(model.memoryTierGiB) <= gibibytes + 0.5
                && (model.minimumSplash.map { build.isAtLeast($0) } ?? true)
        }
    }

    /// The suggestions of `available` by section, in the order the sections
    /// first appear in `all`, without the sections that have none.
    static func sections(
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
        build: SplashBuild
    ) -> [(title: String, models: [SuggestedModel])] {
        let models = available(physicalMemory: physicalMemory, build: build)
        var titles: [String] = []
        for model in models where !titles.contains(model.group) { titles.append(model.group) }
        return titles.map { title in (title, models.filter { $0.group == title }) }
    }

    /// `128 GB`, as Apple names the memory.
    static func memoryDescription(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> String {
        "\(Int((Double(physicalMemory) / Double(1 << 30)).rounded())) GB"
    }
}

/// The suggestions as a menu that fills a model field. Hidden on a Mac too
/// small for any of them; the field still takes any model.
struct ModelSuggestionsMenu: View {
    @Binding var model: String
    /// The engine the suggestions are for.
    let build: SplashBuild

    var body: some View {
        let sections = SuggestedModel.sections(build: build)
        if !sections.isEmpty {
            Menu("Suggestions") {
                ForEach(sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.models) { suggestion in
                            Button(suggestion.menuTitle) { model = suggestion.modelID }
                        }
                    }
                }
            }
            .fixedSize()
            .help("The best known model for each memory size up to this Mac's \(SuggestedModel.memoryDescription())")
        }
    }
}
