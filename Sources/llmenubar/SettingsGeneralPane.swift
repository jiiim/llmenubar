// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

extension SettingsView {
    var generalPane: some View {
        Form {
            paneIntro(
                "LLMenuBar",
                "Start, stop and configure a local inference engine for Apple silicon, from the menu bar."
            )

            Section("Engine") {
                pathRow(
                    "splash",
                    field: .splash,
                    errorKey: .splashPath,
                    help: "The splash command LLMenuBar runs, such as /opt/homebrew/bin/splash, or Splash.app to run the Splash desktop app's own runtime."
                )
                LabeledContent("Version") {
                    Text(splashVersionText)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Application") {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
                    .help("Changes take effect immediately.")
                Toggle(
                    "Show generation speed in menu bar",
                    isOn: performanceDisplayBinding
                )
                .help("Shows the generation speed of the latest request, such as 36.7 t/s, beside the logo.")
                Toggle(
                    "Keep Mac awake while the server is running",
                    isOn: keepAwakeBinding
                )
                .help(
                    "Only when connected to a power adapter. The display still "
                    + "sleeps, and closing the lid or sleeping from the Apple "
                    + "menu still sleeps the Mac."
                )
                Toggle("Let the Mac sleep while answering", isOn: $editor.draft.allowIdleSleep)
                    .help("By default the engine keeps the Mac awake until its requests finish; the display may still sleep. Takes effect with Apply.")
                Toggle(
                    "Confirm before quitting while the server is active",
                    isOn: quitConfirmationBinding
                )
                .help(
                    "Asks before quitting when the engine is starting, running, "
                    + "or restarting. Quitting stops the server and interrupts "
                    + "connected clients."
                )
                Toggle(
                    "Restart the server automatically after a crash or if it stops responding",
                    isOn: autoRestartBinding
                )
                .help(
                    "One automatic restart per incident. If it stops again "
                    + "before it has been healthy for five minutes, it stays "
                    + "stopped and reports the problem."
                )
            }

            Section("Environment") {
                VStack(alignment: .leading, spacing: 4) {
                    TextEditor(text: $editor.draft.environment)
                        .font(.system(.callout, design: .monospaced))
                        .autocorrectionDisabled()
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 40)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel("Environment variables")
                    Text("Extra variables for the engine, one NAME=VALUE per line.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let error = validationErrors[.environment] {
                        validationLabel(error, for: .environment)
                    }
                }
            }

            Section("Command preview") {
                HStack(alignment: .top, spacing: 6) {
                    Text(SplashCommand.preview(configuration: editor.candidate(from: draft)))
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    CopyButton(help: "Copy command (secret values are left out)") { copyCommandPreview() }
                }
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    // Selectable text here goes blank after the selection
                    // loses focus, so the command is copied whole instead.
                    .contextMenu {
                        Button("Copy Command") { copyCommandPreview() }
                    }
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Button("Restore All Engine Options to Defaults", role: .destructive) {
                        draft = draft.restoringDefaults()
                        showNotice("Engine options restored to their defaults in this draft. Apply to use them.")
                    }
                    Text("Clears every option on the Model, Server, Memory, SSD Cache and API panes except which model is served and the Hugging Face token, and leaves LLMenuBar's own General and Diagnostics settings alone. Changes take effect only after Apply.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

}
