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
                    note: NativeContextWindow.note(for: draft)
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
                .help(derived.build.hasCachedStatesOption
                    ? "16-bit halves the state each running request holds."
                    : "16-bit halves each state, so memory and the SSD cache hold about twice as many.")
                if derived.build.hasCachedStatesOption || draft.cachedStates != .standard {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Cached states", selection: $editor.draft.cachedStates) {
                            ForEach(ServerConfiguration.CachedStates.allCases, id: \.self) {
                                Text($0.title(engineHasOption: derived.build.hasCachedStatesOption)).tag($0)
                            }
                        }
                        Text("8-bit stores about a quarter of an fp32 state in memory and on the SSD, and a restored state can differ at near ties. Exact keeps the Recurrent state precision, so a restore is exact.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let error = validationErrors[.cachedStates] {
                            validationLabel(error, for: .cachedStates)
                        }
                    }
                } else {
                    // This engine keeps cached states as the Recurrent state
                    // above, so there is nothing to choose and no 8-bit default.
                    Text("This engine stores cached states in the Recurrent state precision. Splash 1.7.0 and later can store them as 8-bit codes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Recalibrate the Neural Engine", isOn: $editor.draft.recalibrateANE)
                        .help("Measures the Neural Engine's share of long prompts again at every start while this is on, instead of taking the one this Mac kept.")
                    if let error = validationErrors[.recalibrateANE] {
                        validationLabel(error, for: .recalibrateANE)
                    }
                }
            }
        }
    }

}
