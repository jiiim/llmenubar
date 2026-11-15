// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

extension SettingsView {
    var cachePane: some View {
        Form {
            paneIntro(
                "SSD Cache",
                "The engine keeps the prompts it has read on the SSD, so a conversation can go on where it left off."
            )

            Section("Size") {
                textRow(
                    "Cache size",
                    text: $editor.draft.maxCacheDisk,
                    field: .maxCacheDisk,
                    prompt: "Auto",
                    note: "Auto follows the disk's free space, up to 32G. Use a size such as 16G, or 0 to turn the cache off."
                )
                if draft.maxCacheDisk != "0" {
                    textRow(
                        "Writes a day",
                        text: $editor.draft.maxCacheDiskWrites,
                        field: .maxCacheDiskWrites,
                        prompt: "No limit",
                        note: "The most the cache writes in a day, such as 200G, to spare the SSD."
                    )
                }
            }

            if draft.maxCacheDisk != "0" {
                Section("Keeping the cache") {
                    Toggle("Keep after stopping", isOn: $editor.draft.persistentCache)
                        .help("The next start of the model goes on from the prompts it kept. Off by default.")
                    if draft.persistentCache {
                        pathRow(
                            "Cache folder",
                            field: .cacheDirectory,
                            errorKey: .cacheDirectory,
                            help: "Where the cache lives. Blank uses ~/Library/Caches/Splash/prefix-cache. The cache holds prompt text, so the folder is created for you alone."
                        )
                    }
                }
            }
        }
    }

}
