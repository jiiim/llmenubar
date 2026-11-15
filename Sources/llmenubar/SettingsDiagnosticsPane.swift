// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

extension SettingsView {
    var diagnosticsPane: some View {
        Form {
            paneIntro(
                "Diagnostics",
                "The engine's console output is captured in the log."
            )

            Section("Server log") {
                pathRow(
                    "Log folder",
                    field: .logDirectory,
                    errorKey: nil,
                    help: "Where LLMenuBar keeps the captured server output"
                )
                fileNameRow(
                    "Log file name",
                    help: "stdout and stderr captured by LLMenuBar"
                )
                textRow(
                    "Maximum size per log (MB)",
                    text: logSizeTextBinding,
                    field: .logMaxSizeMB,
                    prompt: "10",
                    note: "From \(ConfigurationLimits.minLogSizeMB) to \(ConfigurationLimits.maxLogSizeMB) MB. One rotated backup is retained; total log storage may reach twice this size."
                )
                LabeledContent("Log files") {
                    HStack {
                        Button("Open Log in Console") {
                            ServerLogActions.openInConsole(logPath: server.logPath)
                        }
                        Button("Delete Logs", role: .destructive, action: deleteLogs)
                            .disabled(deleteLogsDisabled)
                    }
                }
                // The buttons act on the log the app is using, which is not the
                // draft's path until the draft is applied (and the engine
                // restarted, while it runs).
                if server.logPath != draft.normalized().logPath {
                    Text("Open and Delete act on \((server.logPath as NSString).abbreviatingWithTildeInPath) until the new location is applied.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Crash trace") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Record a crash trace if the engine fails", isOn: $editor.draft.crashTrace)
                    Text("Gives the engine SPLASH_CRASH_TRACE=1. It writes its last requests to ~/Library/Logs/Splash/crash, keeping the newest four. A trace can contain private conversation data.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

}
