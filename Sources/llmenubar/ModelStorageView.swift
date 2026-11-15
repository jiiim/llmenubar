// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

/// Where a Hugging Face model downloads to, the space there, and whether the
/// chosen model fits. Shared by the setup window and the Model pane, which add
/// the buttons that change the folder.
struct ModelStorageView: View {
    /// The Hugging Face model in the field.
    let model: String
    let languageOnly: Bool
    /// The folder chosen in LLMenuBar; blank for Hugging Face's own setting.
    let setting: String
    /// The environment setting's lines, which may set the cache too.
    let environmentText: String
    var revision: String = ""
    /// The Hugging Face token, for a private or gated model's listing.
    var token: String = ""

    @State private var result: ModelStorageResult?
    /// The free space, read off the main actor. A reading is for one folder.
    @State private var freeSpace: (path: String, bytes: Int64?)?

    private var location: ModelCache.Location {
        ModelCache.effectiveLocation(setting: setting, environmentText: environmentText)
    }

    private var check: ModelStorageCheck {
        ModelStorageCheck(model: model, languageOnly: languageOnly, location: location, revision: revision,
                          authenticated: !token.isEmpty)
    }

    var body: some View {
        let location = location
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                Text(PathText.presenting(location.path))
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(location.path)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("Download location")
            .accessibilityValue(location.path)

            Text("\(location.source.caption) Models download here. Existing downloads stay where they are, and models already in this folder are used, not downloaded again.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            freeSpaceLine
            outcomeLine
        }
        .task(id: check) {
            let path = location.path
            let bytes = await Task.detached(priority: .utility) { ModelCache.freeBytes(at: path) }.value
            guard !Task.isCancelled else { return }
            freeSpace = (path, bytes)
            // Typing a name, or a folder, passes through many values.
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let result = await ModelStorageReport.assess(model: model, languageOnly: languageOnly, location: location, revision: revision, token: token)
            guard !Task.isCancelled else { return }
            self.result = ModelStorageResult(check: check, report: result)
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Only a report for what is on screen: one for another folder or model is
    /// out of date for the moment it takes to replace it.
    private var current: ModelStorageReport? {
        result?.report(for: check)
    }

    @ViewBuilder
    private var freeSpaceLine: some View {
        // The reading for this folder, or none yet: nothing here touches the
        // disk, so a slow or stalled volume cannot hold up the window.
        let reading: (bytes: Int64?, known: Bool) = current.map { ($0.freeBytes, true) }
            ?? (freeSpace.flatMap { $0.path == location.path ? ($0.bytes, true) : nil } ?? (nil, false))
        if reading.known {
            if let free = reading.bytes {
                Text("Free space here: \(Self.size(free))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Label("That folder's disk is not connected.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var outcomeLine: some View {
        if let current, HubModelFiles.parse(model) != nil {
            switch current.outcome {
            case .unknown:
                EmptyView()
            case .alreadyDownloaded:
                Label("This model is already downloaded here.", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            case .fits(let bytes):
                Text("This model needs about \(Self.size(bytes)) more, and fits. A draft model is not counted.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .wontFit(let bytes):
                Label(
                    "This model needs about \(Self.size(bytes)) more, and only \(Self.size(current.freeBytes ?? 0)) is free here. Choose another location or a smaller model.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The folder panel for the download location, shared by both windows.
enum ModelCacheFolderPanel {
    @MainActor
    static func choose(startingAt path: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose Download Location"
        panel.message = "Choose the folder Hugging Face models download to."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        var start = path
        while !start.isEmpty, start != "/", !FileManager.default.fileExists(atPath: start) {
            start = (start as NSString).deletingLastPathComponent
        }
        panel.directoryURL = URL(fileURLWithPath: start.isEmpty ? NSHomeDirectory() : start)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return PathText.storingAbsolute(url.path)
    }
}
