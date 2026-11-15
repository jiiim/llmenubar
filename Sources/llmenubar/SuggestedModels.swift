// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation
import SwiftUI

/// Models offered by name on the setup window: the best known one for each
/// memory size Macs come in, up to the memory this Mac has.
///
/// The list is short on purpose: the Qwen3.8 models Splash serves best, as
/// Unsloth's GGUFs. Anything else is typed in.
struct SuggestedModel: Equatable, Identifiable, Sendable {
    let family: String
    let repository: String
    let variant: String
    /// The GGUF's size on disk, in GiB.
    let sizeGiB: Double
    /// The memory size, in GB, this is the best known model for. A Mac with
    /// more memory is offered it too, beside the better ones its own size has.
    let memoryTierGiB: Int

    var id: String { modelID }

    /// What `--model` takes: `owner/repo:VARIANT`.
    var modelID: String { "\(repository):\(variant)" }

    /// `UD-Q4_K_XL, 104 GB`.
    var detail: String { "\(variant), \(Int(sizeGiB.rounded())) GB" }

    /// `128 GB Mac: Qwen3.8 Flash Next, UD-Q4_K_XL, 104 GB`.
    var menuTitle: String { "\(memoryTierGiB) GB Mac: \(family), \(detail)" }

    static let flashNext = "Qwen3.8 Flash Next"
    static let dense27B = "Qwen3.8 27B"

    // Sizes are the sum of each variant's files on Hugging Face. Each model
    // leaves its tier at least a tenth over its size for the context and
    // macOS. Splash refuses a GGUF that is mostly unquantized, so BF16 is
    // never offered and the 256 GB model is also the best for 512 GB.
    static let all: [SuggestedModel] = [
        .init(family: flashNext, repository: "unsloth/Qwen3.8-Flash-Next-GGUF", variant: "Q8_0", sizeGiB: 185.6, memoryTierGiB: 256),
        .init(family: flashNext, repository: "unsloth/Qwen3.8-Flash-Next-GGUF", variant: "UD-Q6_K_XL", sizeGiB: 157.5, memoryTierGiB: 192),
        .init(family: flashNext, repository: "unsloth/Qwen3.8-Flash-Next-GGUF", variant: "UD-Q4_K_XL", sizeGiB: 103.7, memoryTierGiB: 128),
        .init(family: flashNext, repository: "unsloth/Qwen3.8-Flash-Next-GGUF", variant: "UD-IQ3_XXS", sizeGiB: 77.9, memoryTierGiB: 96),
        .init(family: dense27B, repository: "unsloth/Qwen3.8-27B-GGUF", variant: "UD-Q8_K_XL", sizeGiB: 29.3, memoryTierGiB: 64),
        .init(family: dense27B, repository: "unsloth/Qwen3.8-27B-GGUF", variant: "UD-Q6_K", sizeGiB: 20.5, memoryTierGiB: 48),
        .init(family: dense27B, repository: "unsloth/Qwen3.8-27B-GGUF", variant: "UD-Q4_K_M", sizeGiB: 15.4, memoryTierGiB: 32),
        .init(family: dense27B, repository: "unsloth/Qwen3.8-27B-GGUF", variant: "UD-IQ3_XXS", sizeGiB: 10.2, memoryTierGiB: 24),
    ]

    /// The suggestions for a Mac with `physicalMemory` bytes, the one for its
    /// own memory size first.
    static func available(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> [SuggestedModel] {
        let gibibytes = Double(physicalMemory) / Double(1 << 30)
        return all.filter { Double($0.memoryTierGiB) <= gibibytes + 0.5 }
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

    var body: some View {
        let suggestions = SuggestedModel.available()
        if !suggestions.isEmpty {
            Menu("Suggestions") {
                ForEach(suggestions) { suggestion in
                    Button(suggestion.menuTitle) { model = suggestion.modelID }
                }
            }
            .fixedSize()
            .help("The best known model for each memory size up to this Mac's \(SuggestedModel.memoryDescription())")
        }
    }
}
