// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

extension SettingsView {
    var modelPane: some View {
        Form {
            paneIntro(
                "Model",
                "The engine serves one model at a time, from Hugging Face or from files on this Mac."
            )

            Section("Source") {
                Picker("Model from", selection: $editor.draft.modelSource) {
                    Text("Hugging Face").tag(ServerConfiguration.ModelSource.huggingFace)
                    Text("On this Mac").tag(ServerConfiguration.ModelSource.local)
                }
                .pickerStyle(.segmented)
                .onChange(of: draft.modelSource) { _, _ in requestDerivedRefresh() }
            }

            switch draft.modelSource {
            case .huggingFace:
                Section("Hugging Face") {
                    textRow(
                        "Model",
                        text: $editor.draft.huggingFaceModel,
                        field: .huggingFaceModel,
                        prompt: "owner/repo:VARIANT",
                        note: "For example unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M. The engine downloads it on the first start, with the draft that matches it.",
                        monospaced: true,
                        trailing: {
                            AnyView(HStack(spacing: 8) {
                                ModelSuggestionsMenu(model: $editor.draft.huggingFaceModel, build: derived.build)
                                recentModelsMenu
                            })
                        }
                    )
                    textRow(
                        "Revision",
                        text: $editor.draft.revision,
                        field: .revision,
                        prompt: "Default branch",
                        note: "A branch, tag or commit of the repository."
                    )
                    HubTokenField(token: draft.huggingFaceToken) {
                        secretRow(
                            "Access token",
                            text: $editor.draft.huggingFaceToken,
                            field: .huggingFaceToken,
                            prompt: "From hf auth login",
                            note: "For a private or gated model. Blank uses the token that hf auth login saved. The token is kept in your keychain."
                        )
                    }
                    textRow(
                        "Draft",
                        text: $editor.draft.draftModel,
                        field: .draftModel,
                        prompt: "Chosen by the engine",
                        note: "A DFlash2 draft repository to use instead of the one the engine picks for the model, as owner/repo.",
                        monospaced: true
                    )
                }
            case .local:
                Section("Files on this Mac") {
                    pathRow(
                        "Model",
                        field: .model,
                        errorKey: .modelPath,
                        help: "A GGUF file, or the folder of a GGUF or MLX model. For a split GGUF, choose its first part."
                    )
                    pathRow(
                        "Vision projector",
                        field: .visionProjector,
                        errorKey: .visionProjectorPath,
                        help: draft.languageOnly
                            ? "Not used while Text only is on."
                            : "The GGUF projector (mmproj) that lets a GGUF model read images and PDFs. Without one, a GGUF model serves text only."
                    )
                    pathRow(
                        "Draft",
                        field: .draft,
                        errorKey: .draftModel,
                        help: "The folder of a DFlash2 draft. Without one, the engine uses the model family's draft from the Hugging Face cache."
                    )
                }
            }

            if draft.modelSource == .huggingFace {
                Section("Download location") {
                    ModelStorageView(
                        model: draft.huggingFaceModel,
                        languageOnly: draft.languageOnly,
                        setting: draft.modelCacheDirectory,
                        environmentText: draft.environment, revision: draft.revision,
                        token: draft.huggingFaceToken
                    )
                    HStack {
                        Button("Choose Folder…") {
                            let start = ModelCache.effectiveLocation(
                                setting: draft.modelCacheDirectory, environmentText: draft.environment
                            ).path
                            if let folder = ModelCacheFolderPanel.choose(startingAt: start) {
                                draft.modelCacheDirectory = folder
                            }
                        }
                        Button("Use Default Location") { draft.modelCacheDirectory = "" }
                            .disabled(draft.modelCacheDirectory.isEmpty)
                            .help("Download to the default location, or the Hugging Face setting this app inherits")
                    }
                    if let error = validationErrors[.modelCacheDirectory] {
                        validationLabel(error, for: .modelCacheDirectory)
                    }
                }
            }

            Section("Chat template") {
                pathRow(
                    "Template file",
                    field: .chatTemplate,
                    errorKey: .chatTemplatePath,
                    help: "A Jinja chat template to render every request with, in place of the model's own. The engine reads it once at startup and refuses one that cannot render a conversation."
                )
                Button("Use the Model's Own") { editor.draft.chatTemplatePath = ""; requestDerivedRefresh() }
                    .disabled(draft.chatTemplatePath.isEmpty)
            }

            Section("Options") {
                toggleRow(
                    "Text only",
                    isOn: $editor.draft.languageOnly,
                    note: "Skips vision preparation and loading. Image and PDF input is refused, and less memory is used."
                )
                .onChange(of: draft.languageOnly) { _, _ in requestDerivedRefresh() }
                toggleRow(
                    "Work offline",
                    isOn: $editor.draft.offline,
                    note: "Each start of a Hugging Face model asks Hugging Face, for up to 5 seconds, whether the model or its draft has a newer version, and downloads what changed. On, the engine starts the copy already downloaded and asks nothing, so the model must be downloaded already. Files on this Mac never contact Hugging Face."
                )
            }
        }
    }

}
