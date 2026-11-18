// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

extension SettingsView {
    var serverPane: some View {
        Form {
            paneIntro(
                "Server",
                "Where the engine answers: the chat page, coding agents and other apps connect here."
            )

            Section("Address") {
                Picker("Listen on", selection: hostChoiceBinding) {
                    Text("This Mac only").tag(HostChoice.thisMac)
                    Text("All networks").tag(HostChoice.allNetworks)
                    Text("UNIX socket").tag(HostChoice.unixSocket)
                    Text("Another address").tag(HostChoice.other)
                }
                if hostChoiceBinding.wrappedValue == .other {
                    textRow(
                        "Address",
                        text: $editor.draft.host,
                        field: .host,
                        prompt: "127.0.0.1",
                        note: nil,
                        monospaced: true
                    )
                } else if hostChoiceBinding.wrappedValue == .unixSocket {
                    textRow(
                        "Socket",
                        text: socketPathBinding,
                        field: .host,
                        prompt: Self.suggestedSocketPath,
                        note: "The engine creates the socket here and removes it when it stops. Only users with write access to it can connect, so it needs no API key.",
                        monospaced: true
                    )
                } else if let error = validationErrors[.host] {
                    validationLabel(error, for: .host)
                }
                textRow(
                    "Port",
                    text: portTextBinding,
                    field: .port,
                    prompt: "8000",
                    note: hostChoiceBinding.wrappedValue == .unixSocket
                        ? "A socket has no port. This one only names the engine's lock file, so two sockets need two ports."
                        : "From \(ConfigurationLimits.minPort) to \(ConfigurationLimits.maxPort)."
                )
                if !ListenAddress(draft.host).isLoopback, ListenAddress(draft.host).isWellFormed, draft.apiKey.isEmpty {
                    Label(
                        "Any device on these networks can use the model. Set an API key in the API pane to require one.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
            }

            Section("Access") {
                chatPageRow
                textRow(
                    "Host names",
                    text: $editor.draft.allowedHosts,
                    field: .allowedHosts,
                    prompt: "None",
                    note: "Other names clients reach this Mac by, such as mymac.local. Separate several with commas."
                )
                textRow(
                    "Web origins",
                    text: $editor.draft.allowedOrigins,
                    field: .allowedOrigins,
                    prompt: "None",
                    note: "Websites allowed to use the model from a browser, such as https://example.com; * allows any. Separate several with commas."
                )
            }
        }
    }

}
