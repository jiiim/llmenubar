// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

extension SettingsView {
    var requestsPane: some View {
        Form {
            paneIntro(
                "Requests",
                "What the engine does with a request: how much it thinks, the limits requests meet, and how it shares time between them."
            )

            Section("Thinking") {
                Picker("Thinking", selection: $editor.draft.reasoningEffort) {
                    ForEach(ServerConfiguration.ReasoningEffort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .help("How much the model thinks.")
                Picker("Applies to", selection: $editor.draft.reasoningScope) {
                    ForEach(ServerConfiguration.ReasoningScope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(editor.draft.reasoningEffort == .modelDefault)
                .help("A request that sets its own effort keeps it, unless this is Every request.")
                if editor.draft.reasoningEffort != .modelDefault, editor.draft.reasoningScope == .everyRequest {
                    Text("Every request thinks at this effort, whatever the client asks. Off stops thinking for clients that ask for it on every turn. A model that decides for itself whether to think, such as Flint or Inkling, does not start with this.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let error = validationErrors[.reasoningEffort] {
                    validationLabel(error, for: .reasoningEffort)
                }
                textRow(
                    "Thinking tokens",
                    text: $editor.draft.thinkingTokenBudget,
                    field: .thinkingTokenBudget,
                    prompt: "No limit",
                    note: "Thinking tokens of a request that sets no budget, after which its thinking closes."
                )
                textRow(
                    "Thinking end text",
                    text: $editor.draft.thinkingEndText,
                    field: .thinkingEndText,
                    prompt: "</think>",
                    note: "A sentence that turns to the answer where a thinking budget runs out."
                )
            }

            Section("Limits") {
                textRow(
                    "Request size",
                    text: $editor.draft.maxRequestSize,
                    field: .maxRequestSize,
                    prompt: "128M",
                    note: "The largest request body, images and PDFs included."
                )
                textRow(
                    "Image pixels",
                    text: $editor.draft.maxImagePixels,
                    field: .maxImagePixels,
                    prompt: "4194304",
                    note: "The most pixels per image after resizing, from \(SplashOptionValues.imagePixelRange.lowerBound) to \(SplashOptionValues.imagePixelRange.upperBound)."
                )
                textRow(
                    "Request timeout",
                    text: $editor.draft.requestTimeout,
                    field: .requestTimeout,
                    prompt: "None",
                    note: "How long a queued or running request lasts before it ends with an error, such as 30m."
                )
                textRow(
                    "Stop grace seconds",
                    text: $editor.draft.shutdownTimeout,
                    field: .shutdownTimeout,
                    prompt: "5",
                    note: "How long running requests get to finish when the engine stops, from 0 to 15. 0 ends them at once."
                )
                textRow(
                    "Requests at once",
                    text: $editor.draft.queueSize,
                    field: .queueSize,
                    prompt: "32",
                    note: "Requests taken at once, running or waiting; more are turned away."
                )
                textRow(
                    "Running at once",
                    text: $editor.draft.maxConcurrentRequests,
                    field: .maxConcurrentRequests,
                    prompt: "4",
                    note: "Requests the engine runs together, \(SplashOptionValues.concurrentRequestRange.lowerBound) to \(SplashOptionValues.concurrentRequestRange.upperBound). More let more clients be answered together, each a little slower, and take memory that can leave less context."
                )
            }

            Section {
                let expanded = samplingExpanded
                Button {
                    expanded.wrappedValue.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                            .frame(width: 16)
                        Text("Sampling defaults")
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
                .accessibilityHint("Shows or hides the sampling values")

                if expanded.wrappedValue {
                    Text("Values for requests that set none. A blank one keeps the default.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(ServerConfiguration.Config.samplingParameters, id: \.name) { parameter in
                        textRow(
                            parameter.title,
                            text: Binding(
                                get: { editor.draft[keyPath: parameter.keyPath] },
                                set: { editor.draft[keyPath: parameter.keyPath] = $0 }
                            ),
                            field: parameter.field,
                            prompt: parameter.defaultText,
                            note: "Takes \(parameter.rule.requirement). \(parameter.defaultNote)",
                            monospaced: true
                        )
                    }
                }
            }

            Section("Behaviour") {
                textRow(
                    "Answering while reading",
                    text: $editor.draft.decodeShare,
                    field: .decodeShare,
                    prompt: "0.5",
                    note: "Decode time owed per unit of prefill time while other requests decode. 0 alternates one command each."
                )
                Picker("Repeatable answers", selection: $editor.draft.verifyRows) {
                    ForEach(ServerConfiguration.VerifyRows.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .help("All checks every row of a draft block, so a mixture-of-experts model repeats its answers as a dense model does.")
            }
        }
    }

    /// Open when a value is set or wrong, and otherwise until the user opens it.
    private var samplingExpanded: Binding<Bool> {
        Binding(
            get: {
                let draft = editor.draft
                let errors = ServerConfiguration.Config.samplingParameters.contains {
                    validationErrors[$0.field] != nil
                }
                return errors || (samplingOpen ?? draft.hasSamplingDefaults)
            },
            set: { samplingOpen = $0 }
        )
    }
}
