// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

extension SettingsView {
    var memoryPane: some View {
        Form {
            paneIntro(
                "Memory",
                "The engine sizes memory and context automatically, up to the model's native window. Set a limit to leave room for other apps."
            )

            Section("Limits") {
                textRow(
                    "Memory limit",
                    text: $editor.draft.maxMemory,
                    field: .maxMemory,
                    prompt: "Auto",
                    note: "The most Metal memory the engine uses, such as 28G. It can only lower the automatic limit."
                )
                textRow(
                    "Context length",
                    text: $editor.draft.maxContext,
                    field: .maxContext,
                    prompt: "Auto",
                    note: "Tokens, with K for 1024 or M for a million, such as 100K or 1M. The native window is \(NativeContextWindow.description). Past it the engine turns on YaRN, which changes answers at every length. Auto serves the native window when memory holds it, and otherwise as much as memory holds."
                )
                textRow(
                    "Free memory when idle",
                    text: $editor.draft.idleRelease,
                    field: .idleRelease,
                    prompt: "10m",
                    note: "How long without a request before the engine frees the model's memory; the next message loads it again. Use off to keep it, or a duration such as 30m."
                )
            }

            Section("Streaming from the SSD") {
                textRow(
                    "Expert memory",
                    text: $editor.draft.expertMemory,
                    field: .expertMemory,
                    prompt: "Auto",
                    note: "RAM for the routed experts of a mixture-of-experts model, such as 16G. The others are read from the SSD. Auto grows the store as memory allows and gives it back when other work needs it; a size fixes it. Use off to load every expert."
                )
                textRow(
                    "PLE table memory",
                    text: $editor.draft.pleMemory,
                    field: .pleMemory,
                    prompt: "Auto",
                    note: "RAM row cache of the PLE table of a Qwen3.8-Flash-Next model, such as 2G. Use off to load the whole table."
                )
                textRow(
                    "Sparse KV memory",
                    text: $editor.draft.sparseKVMemory,
                    field: .sparseKVMemory,
                    prompt: "Auto",
                    note: "RAM cache of the KV blocks of a block-sparse model whose KV is on the SSD, such as 1200M."
                )
            }

            Section("Precision") {
                Picker("KV cache", selection: $editor.draft.kvFormat) {
                    ForEach(ServerConfiguration.KVFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .help("How the model keeps what it has read. 16-bit takes twice the memory.")
                Picker("Recurrent state", selection: $editor.draft.stateFormat) {
                    ForEach(ServerConfiguration.StateFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .help("16-bit halves each state, so memory and the SSD cache hold about twice as many.")
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Activations", selection: $editor.draft.activations) {
                        ForEach(ServerConfiguration.Activations.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text("Auto rounds activations to 8 bits where the GPU multiplies them twice as fast (M5 and later) and keeps them 16-bit elsewhere. 16-bit keeps every activation 16-bit, for evaluations and parity.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let error = validationErrors[.activations] {
                        validationLabel(error, for: .activations)
                    }
                }
                Toggle("Prefill on the GPU alone", isOn: $editor.draft.disableANE)
                    .help("Turns off the Neural Engine for long prompts on a dense model.")
            }
        }
    }

}
