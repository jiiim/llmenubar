// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

extension SettingsView {
    var apiPane: some View {
        Form {
            paneIntro(
                "API",
                "OpenAI and Anthropic compatible endpoints, the key clients send and the names they ask for."
            )

            Section("Addresses") {
                let endpoints = SplashEndpoints(draft.normalized())
                addressRow("OpenAI compatible", url: endpoints.openAIBase, opens: false, enabled: true)
                addressRow("Anthropic compatible", url: endpoints.anthropicBase, opens: false, enabled: true)
                // Listening on every interface: the two above work on this Mac
                // only, so show what another device would use.
                let normalized = draft.normalized()
                ForEach(OtherDeviceEndpoints.entries(host: normalized.host, port: normalized.port,
                                                     names: LocalNetworkNames.current()), id: \.label) { entry in
                    addressRow("OpenAI (\(entry.label))", url: entry.openAI, opens: false, enabled: true)
                    addressRow("Anthropic (\(entry.label))", url: entry.anthropic, opens: false, enabled: true)
                }
                Text("The base URLs clients take.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Access") {
                apiKeyRow
            }

            Section("Model names") {
                if draft.modelSource == .local {
                    textRow(
                        "Name for local files",
                        text: $editor.draft.localModelName,
                        field: .localModelName,
                        prompt: SplashModel.localAPIName(forPath: draft.modelPath),
                        note: "The name clients ask for the model on this Mac. Blank uses the name shown.",
                        monospaced: true,
                        trailing: {
                            let typed = draft.localModelName.trimmingCharacters(in: .whitespaces)
                            let name = typed.isEmpty ? SplashModel.localAPIName(forPath: draft.modelPath) : typed
                            return AnyView(CopyButton(help: "Copy name") { copyText(name) })
                        }
                    )
                }
                textRow(
                    "Other model names",
                    text: $editor.draft.servedModelNames,
                    field: .servedModelNames,
                    prompt: "None",
                    note: "More names requests may give the model, such as gpt-4o for an app that asks for it. Separate several with commas."
                )
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Answer as the first other name", isOn: $editor.draft.announceServedName)
                        .disabled(SplashOptionValues.items(draft.servedModelNames).isEmpty)
                        .help("Replies and the model list give the first other name rather than the model's own.")
                    Text("Replies show the first other name instead of the model's own.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

}
