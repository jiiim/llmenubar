// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

struct InitialSetupView: View {
    /// How the window is told apart from every other.
    static let windowIdentifier = NSUserInterfaceItemIdentifier("llmenubar.initialSetup")
    static let contentWidth: CGFloat = 540

    let onContinue: (
        _ splashPath: String,
        _ model: ServerConfiguration.InitialModel,
        _ modelCacheDirectory: String,
        _ huggingFaceToken: String
    ) -> Void

    /// Where Hugging Face models download to; blank for Hugging Face's own
    /// setting.
    @State private var modelCacheDirectory = ""
    /// The Hugging Face setting found in the user's shell, which was filled in.
    @State private var foundInShell: ModelCache.Location?

    @State private var splashPath = ""
    /// The heights of the scrolling steps and of the buttons below them.
    @State private var stepsHeight: CGFloat = 700
    @State private var buttonsHeight: CGFloat = 60
    /// Splash installs found on this Mac, with their versions. Nil until the
    /// search, which runs each one, has finished.
    @State private var installs: [SplashInstall]?
    /// Whether this is the window in front. The periodic look runs only then.
    @State private var isFront = false
    /// What the chosen executable reported when it was checked.
    @State private var chosenBuild = SplashBuild.unknown
    private let searchesForInstalls: Bool
    @State private var splashError: String?
    @State private var isCheckingSplash = false
    @State private var source: ServerConfiguration.ModelSource = .huggingFace
    @State private var huggingFaceModel = ""
    /// Optional: for a private or gated model.
    @State private var huggingFaceToken = ""
    @State private var localPath = ""
    @State private var localError: String?

    /// `installs` stands in for the search of this Mac, for a view that has to
    /// show a given set of installs.
    init(
        installs: [SplashInstall]? = nil,
        onContinue: @escaping (
            _ splashPath: String,
            _ model: ServerConfiguration.InitialModel,
            _ modelCacheDirectory: String,
            _ huggingFaceToken: String
        ) -> Void
    ) {
        self.onContinue = onContinue
        _installs = State(initialValue: installs)
        searchesForInstalls = installs == nil
    }

    private var canContinue: Bool { blocker == nil }

    /// What stands between the user and Continue, in the order they would meet
    /// it. A disabled button that does not say why reads as a broken one.
    private var blocker: String? {
        if splashPath.isEmpty { return "Choose the engine executable to continue." }
        if isCheckingSplash { return "Checking the engine…" }
        if splashError != nil { return "Choose a working engine executable to continue." }
        switch source {
        case .huggingFace:
            if huggingFaceModel.isEmpty { return "Enter a model to continue." }
            if !SplashModel.isModelID(huggingFaceModel) { return "Fix the model name to continue." }
        case .local:
            if localPath.isEmpty { return "Choose the model files to continue." }
            if localError != nil { return "Choose a model that the engine can load to continue." }
        }
        return nil
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set Up LLMenuBar")
                    .font(.title2.bold())
                Text("To begin using LLMenuBar, first choose the inference engine to run and the model it should serve.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            section("Inference Engine") {
                splashRows
            }

            section("Large Language Model") {
                modelRows
            }
        }
    }

    private var buttons: some View {
        HStack {
            Button("Quit") {
                // Routed through the delegate so the quit policy has one
                // entry point. It always proceeds from here: the server
                // cannot be starting or running before setup completes.
                NSApp.sendAction(#selector(AppDelegate.requestQuit(_:)), to: nil, from: nil)
            }
            Spacer()
            if let blocker {
                Text(blocker)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Continue", action: continueSetup)
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
        }
    }

    /// The tallest the window may be: the screen's usable area, under the menu
    /// bar and above the Dock, less the title bar.
    private var tallestContent: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? .greatestFiniteMagnitude
        let frame = NSRect(x: 0, y: 0, width: Self.contentWidth, height: screen)
        return NSWindow.contentRect(forFrameRect: frame, styleMask: [.titled, .closable]).height
    }

    /// The steps scroll when they do not fit; the buttons stay in view.
    private var scrollHeight: CGFloat {
        SetupWindowSizing.scrollHeight(
            steps: stepsHeight,
            buttons: buttonsHeight,
            tallest: tallestContent
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                steps
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 20)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stepsHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: scrollHeight)
            if SetupWindowSizing.scrolls(steps: stepsHeight, buttons: buttonsHeight, tallest: tallestContent) {
                Divider()
            }
            buttons
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { buttonsHeight = $0 }
        }
        .frame(width: Self.contentWidth)
        .task { await refreshInstalls() }
        // Restarts each time the window comes to the front or leaves it, so
        // while it is behind something there is no timer at all.
        .task(id: isFront) { await watchForInstalls() }
        .onAppear { isFront = NSApp.keyWindow?.identifier == Self.windowIdentifier }
        .task { await findShellCacheSetting() }
        // Someone may install Splash with Homebrew, or download the app, and
        // come back to this window without quitting, so look again each time
        // it is the one in front. A file panel is not this window.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            // Only this window: Settings or About becoming key is not this
            // window coming back, and a file panel is not it either.
            guard (note.object as? NSWindow)?.identifier == Self.windowIdentifier else { return }
            isFront = true
            Task { await refreshInstalls() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            guard (note.object as? NSWindow)?.identifier == Self.windowIdentifier else { return }
            isFront = false
        }
    }

    // MARK: Rows

    /// A titled card, so the two choices read as two steps.
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// A sentence with one linked phrase in it.
    private func linked(_ before: String, _ phrase: String, _ url: URL, _ after: String) -> AttributedString {
        var link = AttributedString(phrase)
        link[AttributeScopes.FoundationAttributes.LinkAttribute.self] = url
        return AttributedString(before) + link + AttributedString(after)
    }

    /// A person who moved their Hugging Face cache set it in a shell profile,
    /// which this app never reads. Ask a login shell once, offer what it says
    /// and save it with the other choices; nothing reads the shell after setup.
    private func findShellCacheSetting() async {
        guard searchesForInstalls else { return }
        let found = await Task.detached(priority: .utility) { LoginShellEnvironment.cacheLocation() }.value
        guard let found, modelCacheDirectory.isEmpty else { return }
        modelCacheDirectory = found.path
        foundInShell = found
    }

    // MARK: Engine rows

    /// Someone may start an install in Terminal and come back, so while this
    /// window is in front, look at the customary places every few seconds. It
    /// is not looked at while the window is behind something: the look on
    /// returning to it covers that. That look
    /// only checks that the files exist; the slower one, which asks each
    /// install for its version, runs only when what exists has changed. The
    /// task ends when the window leaves the front or closes.
    private func watchForInstalls() async {
        guard searchesForInstalls, isFront else { return }
        var retries = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: SplashInstall.watchInterval)
            guard !Task.isCancelled else { return }
            let paths = await Task.detached(priority: .utility) { SplashLauncher.installedPaths() }.value
            let known = installs ?? []
            guard SplashInstall.needsVersionLookup(known: known, paths: paths, unreadableRetriesUsed: retries) else {
                continue
            }
            retries = paths == known.map(\.path) ? retries + 1 : 0
            await refreshInstalls()
        }
    }

    /// Look for installs again. The list keeps showing while it runs, so a
    /// return to the window does not flash it away.
    private func refreshInstalls() async {
        guard searchesForInstalls else { return }
        let found = await Task.detached(priority: .userInitiated) { SplashInstall.detect() }.value
        installs = found
        // A chosen install that has since been removed is no longer chosen.
        if !splashPath.isEmpty, case .failure = SplashLauncher.resolve(path: splashPath) {
            splashPath = ""
            splashError = nil
            isCheckingSplash = false
            chosenBuild = .unknown
        }
        // With nothing chosen, an install that was found is chosen: Homebrew's
        // first, then Splash.app. A choice the user made is left alone.
        if splashPath.isEmpty,
           let found = homebrewInstalls.first ?? appInstalls.first {
            checkSplash(at: found.path)
        }
    }

    private var homebrewInstalls: [SplashInstall] { (installs ?? []).filter { $0.kind == .homebrew } }
    private var otherCommands: [SplashInstall] { (installs ?? []).filter { $0.kind == .command } }
    private var appInstalls: [SplashInstall] { (installs ?? []).filter { $0.kind == .desktopApp } }

    /// Whether the chosen executable is one of the installs listed above the
    /// Choose button.
    private var chosenIsListed: Bool {
        (installs ?? []).contains { PathText.storingAbsolute($0.path) == splashPath }
    }

    /// Homebrew, then Splash.app, then any other location. Each is listed
    /// whether or not it is installed, so the way to get it is in front of the
    /// user.
    @ViewBuilder
    private var splashRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(linked(
                    "Currently, LLMenuBar supports the ",
                    "Splash",
                    SplashInstall.projectURL,
                    " inference engine, which must be installed separately."
                ))
                Text("Select an installed Splash engine from one of the following three places:")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
            Divider().padding(.leading, 16)
            if installs == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for Splash…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            } else {
                if homebrewInstalls.isEmpty {
                    homebrewMissingRow
                } else {
                    ForEach(homebrewInstalls) { installRow($0) }
                }
                ForEach(otherCommands) { installRow($0) }
                if appInstalls.isEmpty {
                    appMissingRow
                } else {
                    ForEach(appInstalls) { installRow($0) }
                }
            }
            otherLocationRow
        }
    }

    /// A Splash found on this Mac: where it is, its release and a button to
    /// use it.
    private func installRow(_ install: SplashInstall) -> some View {
        let selected = PathText.storingAbsolute(install.path) == splashPath
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(install.title).fontWeight(.medium)
                    HStack(spacing: 8) {
                        Text(PathText.presenting(install.path))
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(install.path)
                        if let version = install.version {
                            Text(version)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .layoutPriority(1)
                        }
                    }
                }
                Spacer(minLength: 12)
                if selected {
                    selectionIndicator
                } else {
                    Button("Use") { checkSplash(at: install.path) }
                        .accessibilityLabel("Use \(SplashLauncher.description(ofPath: install.path))")
                }
            }
            if selected { chosenIssue }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .followedByOr()
    }

    private var homebrewMissingRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Homebrew").fontWeight(.medium)
            Text("Not installed. To install it, run this in Terminal:")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(SplashInstall.homebrewInstallCommand)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(SplashInstall.homebrewInstallCommand, forType: .string)
                }
                .accessibilityLabel("Copy the Homebrew install command")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .followedByOr()
    }

    private var appMissingRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Splash.app").fontWeight(.medium)
            HStack(spacing: 4) {
                Text("Not installed.")
                    .foregroundStyle(.secondary)
                Link("Download it from Splash releases", destination: SplashInstall.releasesURL)
            }
            .font(.callout)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .followedByOr()
    }

    /// Any other executable, such as the `splash` file of a source checkout.
    private var otherLocationRow: some View {
        let isChosen = !splashPath.isEmpty && !chosenIsListed
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Another location").fontWeight(.medium)
                    // A chosen path is one line, shortened in the middle. The
                    // instruction shown before a choice wraps so none of it is
                    // lost.
                    if isChosen {
                        HStack(spacing: 8) {
                            Text(PathText.presenting(splashPath))
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(splashPath)
                            if let version = chosenBuild.displayVersion {
                                Text(version)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .layoutPriority(1)
                            }
                        }
                    } else {
                        // Markdown in a literal: `splash` is set in monospace.
                        Text("The `splash` executable or Splash.app from another location.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                if isChosen { selectionIndicator }
                Button("Choose…", action: chooseSplash)
            }
            if isChosen { chosenIssue }
        }
        .padding(16)
    }

    @ViewBuilder
    private var selectionIndicator: some View {
        if isCheckingSplash {
            ProgressView().controlSize(.small)
        } else if splashError == nil {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Chosen")
        }
    }

    @ViewBuilder
    private var chosenIssue: some View {
        if let splashError {
            Label(splashError, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var modelRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Model", selection: $source) {
                Text("Hugging Face").tag(ServerConfiguration.ModelSource.huggingFace)
                Text("On this Mac").tag(ServerConfiguration.ModelSource.local)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Model source")

            switch source {
            case .huggingFace:
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        TextField("owner/repo:VARIANT", text: $huggingFaceModel)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .accessibilityLabel("Hugging Face model")
                        ModelSuggestionsMenu(model: $huggingFaceModel)
                    }
                    Text("For example unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M. The engine downloads it on the first start.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !huggingFaceModel.isEmpty, !SplashModel.isModelID(huggingFaceModel) {
                        Label("Use owner/repo or owner/repo:VARIANT.", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                HubTokenField(token: huggingFaceToken) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Access token (optional)")
                            .fontWeight(.medium)
                        SecureField("From hf auth login", text: $huggingFaceToken)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .accessibilityLabel("Hugging Face access token")
                        Text("For a private or gated model. Blank uses the token that hf auth login saved. The token is kept in your keychain.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Download location")
                        .fontWeight(.medium)
                    ModelStorageView(
                        model: huggingFaceModel,
                        languageOnly: false,
                        setting: modelCacheDirectory,
                        environmentText: "",
                        token: huggingFaceToken
                    )
                    HStack {
                        Button("Choose Folder…") {
                            let start = ModelCache.effectiveLocation(
                                setting: modelCacheDirectory, environmentText: ""
                            ).path
                            if let folder = ModelCacheFolderPanel.choose(startingAt: start) {
                                modelCacheDirectory = folder
                            }
                        }
                        Button("Use Default Location") { modelCacheDirectory = "" }
                            .disabled(modelCacheDirectory.isEmpty)
                            .help("Download to the default location, or the Hugging Face setting this app inherits")
                    }
                    if let foundInShell, modelCacheDirectory == foundInShell.path {
                        Text("Found in your shell's Hugging Face setting\(foundInShell.source.variableName.map { " (\($0))" } ?? ""). It is saved with these choices, so changing your shell profile later does not change it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            case .local:
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(localPath.isEmpty ? "None selected" : PathText.presenting(localPath))
                            .font(.callout)
                            .foregroundStyle(localPath.isEmpty ? Color.secondary : Color.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(localPath)
                        Text("A GGUF file, or the folder of a model.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let localError {
                            Label(localError, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    Spacer(minLength: 12)
                    Button("Choose…", action: chooseLocalModel)
                }
            }

            Text(linked(
                "For more information on choosing a model, see the ",
                "Splash documentation",
                SplashInstall.documentationURL,
                "."
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    // MARK: Actions

    private func chooseSplash() {
        let panel = NSOpenPanel()
        panel.title = "Choose Engine"
        panel.message = "Select the engine executable: the splash command, or Splash.app."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.directoryURL = startingDirectory(for: splashPath)

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        checkSplash(at: url.path)
    }

    private func checkSplash(at path: String) {
        splashPath = PathText.storingAbsolute(path)
        splashError = nil
        chosenBuild = .unknown
        isCheckingSplash = true
        let selectedPath = splashPath
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                SplashDerivedState.inspectSplash(atPath: selectedPath)
            }.value
            guard splashPath == selectedPath else { return }
            splashError = result.issue
            chosenBuild = result.build
            isCheckingSplash = false
        }
    }

    private func chooseLocalModel() {
        let panel = NSOpenPanel()
        panel.title = "Choose Model"
        panel.message = "Select a GGUF file, or the folder of a GGUF or MLX model."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.directoryURL = startingDirectory(for: localPath)

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        localPath = PathText.storingAbsolute(url.path)
        if case .failure(let issue) = SplashModel.inspectLocalModel(atPath: localPath) {
            localError = issue.message
        } else {
            localError = nil
        }
    }

    private func continueSetup() {
        guard canContinue else { return }
        switch source {
        case .huggingFace:
            onContinue(splashPath, .huggingFace(huggingFaceModel), modelCacheDirectory, huggingFaceToken)
        case .local: onContinue(splashPath, .local(localPath), "", "")
        }
    }

    private func startingDirectory(for path: String) -> URL {
        guard !path.isEmpty else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: PathText.expandingTilde(path)).deletingLastPathComponent()
    }
}

@MainActor
final class InitialSetupWindowController: NSWindowController {
    init(
        onContinue: @escaping (
            _ splashPath: String,
            _ model: ServerConfiguration.InitialModel,
            _ modelCacheDirectory: String,
            _ huggingFaceToken: String
        ) -> Void
    ) {
        let view = InitialSetupView(onContinue: onContinue)
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Set Up LLMenuBar"
        window.identifier = InitialSetupView.windowIdentifier
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A rule with "or" in the middle, between two ways of doing the same thing.
private struct OrDivider: View {
    /// A Divider inside an HStack turns vertical, so the rules are drawn.
    private var rule: some View {
        Rectangle().fill(.separator).frame(height: 1)
    }

    var body: some View {
        HStack(spacing: 8) {
            rule
            Text("OR")
                .font(.headline)
                .foregroundStyle(.secondary)
                .fixedSize()
            rule
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("or")
    }
}

private extension View {
    func followedByOr() -> some View {
        VStack(spacing: 0) {
            self
            OrDivider()
        }
    }
}

/// How tall the setup window's scrolling part is. The window is as tall as its
/// steps and buttons need, up to the height the screen allows; past that the
/// steps scroll and the buttons stay in view.
enum SetupWindowSizing {
    static func scrollHeight(steps: CGFloat, buttons: CGFloat, tallest: CGFloat) -> CGFloat {
        max(0, min(steps, tallest - buttons))
    }

    static func scrolls(steps: CGFloat, buttons: CGFloat, tallest: CGFloat) -> Bool {
        steps > tallest - buttons
    }
}
