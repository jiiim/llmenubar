// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

// Shared presentation rows. Draft workflows belong to SettingsEditor.

extension SettingsView {
    // MARK: Panes

    // MARK: Shared rows and helpers

    var splashVersionText: String {
        if isRefreshingDerivedState { return "Checking…" }
        if let version = derived.build.displayVersion { return "Splash \(version)" }
        return draft.hasSplash ? "Unknown" : "Not chosen"
    }

    /// The listening choices Settings offers by name.
    enum HostChoice: Hashable {
        case thisMac
        case allNetworks
        case other
    }

    var hostChoiceBinding: Binding<HostChoice> {
        Binding(
            get: {
                switch draft.host {
                case "127.0.0.1": return .thisMac
                case "0.0.0.0": return .allNetworks
                default: return .other
                }
            },
            set: { choice in
                switch choice {
                case .thisMac: draft.host = "127.0.0.1"
                case .allNetworks: draft.host = "0.0.0.0"
                case .other:
                    // Start the address field empty so it is the user's to fill.
                    if draft.host == "127.0.0.1" || draft.host == "0.0.0.0" { draft.host = "" }
                }
            }
        )
    }

    /// A port as text. Only digits are kept, and a cleared field reads as no
    /// port, which validation then asks for.
    var portTextBinding: Binding<String> {
        Binding(
            get: { draft.port == 0 ? "" : String(draft.port) },
            set: { draft.port = Int($0.filter { $0.isASCII && $0.isNumber }.prefix(5)) ?? 0 }
        )
    }

    var logSizeTextBinding: Binding<String> {
        Binding(
            get: { draft.logMaxSizeMB == 0 ? "" : String(draft.logMaxSizeMB) },
            set: { draft.logMaxSizeMB = Int($0.filter { $0.isASCII && $0.isNumber }.prefix(6)) ?? 0 }
        )
    }

    /// The key clients send. It is a made-up secret for this Mac's own server,
    /// kept in the keychain, and shown as text that can be copied into the
    /// clients that need it.
    var apiKeyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("API key") {
                HStack(spacing: 8) {
                    TextField("", text: $editor.draft.apiKey, prompt: Text("None"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 180, maxWidth: 300)
                        .accessibilityLabel("API key")
                    CopyButton(help: "Copy key") { AddressActions.copySecret(draft.apiKey) }
                        .disabled(draft.apiKey.isEmpty)
                    Button("Generate") { draft.apiKey = APIKeyGenerator.make() }
                }
            }
            Text("Clients must send this key, as a bearer token or an x-api-key header. LLMenuBar gives it to the engine through the SPLASH_API_KEY variable, so it never appears in the command line. The browser chat page asks for it in its sidebar.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let error = validationErrors[.apiKey] {
                validationLabel(error, for: .apiKey)
            }
        }
    }

    /// A switch with what it does written beneath it.
    @ViewBuilder
    func toggleRow(_ title: String, isOn: Binding<Bool>, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: isOn)
            Text(note).font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// The browser chat page: its switch, a warning that nothing protects it,
    /// and its address, which opens when the page is on.
    var chatPageRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Browser chat page", isOn: $editor.draft.chatPageEnabled)
            Text("Without an API key, anyone who can reach the address can use the page.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            addressRow(
                "Chat page",
                url: SplashEndpoints(draft.normalized()).chatPage,
                opens: true,
                enabled: draft.chatPageEnabled
            )
        }
    }

    /// An address in a filled monospaced field, like the paths. `opens` makes a
    /// click open it in the browser; right-click copies it. A row that is not
    /// `enabled` is grayed out and does neither.
    @ViewBuilder
    func addressRow(_ title: String, url: URL?, opens: Bool, enabled: Bool) -> some View {
        LabeledContent(title) {
            AddressField(url: url, opens: opens, enabled: enabled)
        }
    }

    @ViewBuilder
    func paneIntro(_ title: String, _ description: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    func textRow(
        _ title: String,
        text: Binding<String>,
        field: ServerConfiguration.Config.Field,
        prompt: String,
        note: String?,
        monospaced: Bool = false,
        trailing: (() -> AnyView)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                HStack(spacing: 8) {
                    TextField("", text: text, prompt: Text(prompt))
                        .textFieldStyle(.roundedBorder)
                        .font(monospaced ? .system(.body, design: .monospaced) : .body)
                        .frame(minWidth: 180, maxWidth: monospaced ? 340 : 260)
                        .accessibilityLabel(title)
                    if let trailing { trailing() }
                }
            }
            if let note {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
            if let error = validationErrors[field] {
                validationLabel(error, for: field)
            }
        }
    }

    /// A secret typed as dots, which the app keeps in the keychain.
    func secretRow(
        _ title: String,
        text: Binding<String>,
        field: ServerConfiguration.Config.Field,
        prompt: String,
        note: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                SecureField("", text: text, prompt: Text(prompt))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 180, maxWidth: 340)
                    .accessibilityLabel(title)
            }
            Text(note).font(.footnote).foregroundStyle(.secondary)
            if let error = validationErrors[field] {
                validationLabel(error, for: field)
            }
        }
    }

    func pathRow(
        _ title: String,
        field: SettingsPathField,
        errorKey: ServerConfiguration.Config.Field? = nil,
        help: String
    ) -> some View {
        let path = presentedPath(for: field)
        let directory = field.choosesDirectory
        return VStack(alignment: .leading, spacing: 4) {
            // The path sits on its own line rather than in the value slot: a
            // row that has to divide its width between a label, a path, and a
            // button gives the path whatever is left, which for the first row
            // of a section is nothing at all. On its own line it gets the full
            // width, which these paths need anyway.
            LabeledContent(title) {
                HStack(spacing: 8) {
                    if field == .splash { installedSplashMenu }
                    recentPathsMenu(title, field: field)
                    Button(directory ? "Choose Folder…" : field.choosesFileOrDirectory ? "Choose File or Folder…" : "Choose…") {
                        choosePath(field: field)
                    }
                    .accessibilityLabel(
                        directory ? "Choose folder for \(title)" : "Choose file for \(title)"
                    )
                }
            }
            // A filled monospaced field, like the command preview in General:
            // plain text on the card reads as more label, and a path has to be
            // scannable as the row's value. The leading glyph separates a row
            // that picks a folder from one that picks a file.
            HStack(spacing: 6) {
                Image(systemName: directory ? "folder" : "doc")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                Text(path.isEmpty ? "None selected" : path)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if !path.isEmpty {
                    CopyButton(help: "Copy path") { copyPath(for: field) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .help(path)
            .accessibilityLabel("\(title) path")
            .accessibilityValue(path.isEmpty ? "None selected" : path)
            .contextMenu {
                if !path.isEmpty {
                    Button("Copy Path") { copyPath(for: field) }
                }
            }
            Text(help).font(.footnote).foregroundStyle(.secondary)
            if let errorKey, let error = validationErrors[errorKey] {
                validationLabel(error, for: errorKey)
            }
        }
    }

    /// The name half of the log file, which the app creates. Paired with the
    /// folder row above it, which is a panel like every other path.
    @ViewBuilder
    func fileNameRow(_ title: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                TextField("", text: Binding(
                    get: { logNameText },
                    set: { newValue in
                        logNameText = newValue
                        logNameDidChange()
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 260, maxWidth: 420)
                .accessibilityLabel(title)
            }
            Text(help).font(.footnote).foregroundStyle(.secondary)
            if let error = validationErrors[.logPath] {
                validationLabel(error, for: .logPath)
            }
        }
    }

    /// A validation message under the row it is about. Every message sits in
    /// its row's VStack, so the height it adds is its own plus that stack's
    /// spacing, and it reports that height so the window is fitted without
    /// it; see `fitted(_:)`.
    @ViewBuilder
    func validationLabel(
        _ message: String,
        for key: ServerConfiguration.Config.Field
    ) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                validationMessages.heights[key] = height + SettingsValidationMessages.rowSpacing
            }
            .onAppear { validationMessages.shown.insert(key) }
            .onDisappear { validationMessages.shown.remove(key) }
    }

    /// What a row shows for its selection: `~` for the home directory.
    func presentedPath(for field: SettingsPathField) -> String {
        PathText.presenting(storedPath(for: field))
    }

    // MARK: Recent paths

    /// Recently applied paths for a row, when there is another one to switch
    /// to. Entries are shown the way the row shows its value, so two downloads
    /// with the same name stay apart. A file gone from a mounted disk is not
    /// offered; one on an unmounted volume is listed disabled.
    @ViewBuilder
    func recentPathsMenu(_ title: String, field: SettingsPathField) -> some View {
        let alternatives = recentPathAlternatives(for: field)
        let family = field.isFamilySpecific ? ModelFamily.key(of: draft) : nil
        if let recentField = field.recentField, !alternatives.isEmpty {
            Menu {
                ForEach(alternatives, id: \.path) { entry in
                    Button {
                        applyPickedPath(field, path: entry.path)
                    } label: {
                        Text(entry.availability == .available
                             ? PathText.presenting(entry.path)
                             : "\(PathText.presenting(entry.path)) — volume not mounted")
                    }
                    .disabled(entry.availability != .available)
                }
                Divider()
                Button("Clear Menu") {
                    server.clearRecentSelections(field: recentField, family: family)
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isRefreshingDerivedState)
            .help(field.isFamilySpecific ? "Previously used with this model" : "Previously used paths")
            .accessibilityLabel("Previously used paths for \(title)")
        }
    }

    /// The Hugging Face models applied before, other than the one in the
    /// field. Separate from the suggestions: those are chosen for this Mac, these
    /// are the user's own history.
    @ViewBuilder
    var recentModelsMenu: some View {
        let current = draft.huggingFaceModel.trimmingCharacters(in: .whitespaces)
        let models = server.recentSelections.recentPaths(for: .huggingFaceModel).filter { $0 != current }
        if !models.isEmpty {
            Menu {
                ForEach(models, id: \.self) { model in
                    Button(model) { draft.huggingFaceModel = model }
                }
                Divider()
                Button("Clear Menu") {
                    server.clearRecentSelections(field: .huggingFaceModel)
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Previously used models")
            .accessibilityLabel("Previously used Hugging Face models")
        }
    }

    /// The Splash installs found on this Mac, other than the one chosen.
    @ViewBuilder
    var installedSplashMenu: some View {
        let current = ServerConfiguration.recentFileKey(draft.splashPath)
        let found = SplashLauncher.installedPaths().filter { ServerConfiguration.recentFileKey($0) != current }
        if !found.isEmpty {
            Menu {
                ForEach(found, id: \.self) { path in
                    Button(SplashLauncher.description(ofPath: path)) {
                        applyPickedPath(.splash, path: path)
                    }
                }
            } label: {
                Image(systemName: "sparkle.magnifyingglass")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Splash installs found on this Mac")
            .accessibilityLabel("Splash installs found on this Mac")
        }
    }

    struct RecentPathEntry {
        let path: String
        let availability: ServerConfiguration.PathAvailability
    }

    func recentPathAlternatives(for field: SettingsPathField) -> [RecentPathEntry] {
        guard let recentField = field.recentField else { return [] }
        let family = field.isFamilySpecific ? ModelFamily.key(of: draft) : nil
        // A projector or draft is offered only once the model says whose it is.
        if field.isFamilySpecific, family == nil { return [] }
        let current = ServerConfiguration.recentFileKey(storedPath(for: field))
        return server.recentSelections.recentPaths(for: recentField, family: family).compactMap { path in
            guard ServerConfiguration.recentFileKey(path) != current else { return nil }
            let availability = ServerConfiguration.recentPathAvailability(path)
            return availability == .missing ? nil : RecentPathEntry(path: path, availability: availability)
        }
    }
}

// MARK: - Choice titles

extension ServerConfiguration.KVFormat {
    var title: String {
        switch self {
        case .standard: return "Engine default (8-bit)"
        case .int8: return "8-bit (INT8)"
        case .bf16: return "16-bit (BF16)"
        }
    }
}

extension ServerConfiguration.StateFormat {
    var title: String {
        switch self {
        case .standard: return "Engine default (32-bit)"
        case .fp32: return "32-bit (FP32)"
        case .bf16: return "16-bit (BF16)"
        }
    }
}

extension ServerConfiguration.Activations {
    var title: String {
        switch self {
        case .standard: return "Engine default (auto)"
        case .bf16: return "16-bit (BF16)"
        }
    }
}

extension ServerConfiguration.ReasoningEffort {
    var title: String {
        switch self {
        case .modelDefault: return "Model default"
        case .off: return "Off"
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high"
        case .max: return "Maximum"
        }
    }
}

extension ServerConfiguration.VerifyRows {
    var title: String {
        switch self {
        case .standard: return "Engine default"
        case .auto: return "Auto"
        case .all: return "All rows"
        }
    }
}

/// An address shown as text. It opens on a click when `opens`, copies from the
/// context menu, and is grayed out when it is not `enabled`.
struct AddressField: View {
    let url: URL?
    let opens: Bool
    let enabled: Bool
    var body: some View {
        let text = url?.absoluteString ?? "Not a valid address"
        HStack(spacing: 6) {
            Group {
                if opens, enabled, let url {
                    Button { AddressActions.open(url) } label: { label(text, color: .accentColor) }
                        .buttonStyle(.plain)
                        .help("Open \(text)")
                } else {
                    label(text, color: enabled ? .primary : .secondary)
                }
            }
            .contextMenu {
                if enabled, let url {
                    Button("Copy Address") { AddressActions.copy(url) }
                }
            }
            .accessibilityLabel(text)
            if enabled, let url {
                CopyButton(help: "Copy address") { AddressActions.copy(url) }
            }
        }
    }

    private func label(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.disabled)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .opacity(enabled ? 1 : 0.5)
    }
}

/// The copy icon beside a value: one click copies it, and the icon shows a
/// check mark for a moment so the click is seen to have worked.
struct CopyButton: View {
    let help: String
    let action: () -> Void
    @State private var copied = false

    var body: some View {
        Button {
            action()
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            // Both marks stay in the layout and one is shown, so the button
            // keeps the size of the larger and the row never changes height.
            ZStack {
                Image(systemName: "square.on.square").opacity(copied ? 0 : 1)
                Image(systemName: "checkmark").opacity(copied ? 1 : 0)
            }
            .frame(width: 18)
            .accessibilityHidden(true)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}
