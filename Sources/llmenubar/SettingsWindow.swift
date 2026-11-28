// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings view

/// Hosted by the app's `Settings` scene. The window toolbar switches panes,
/// and a staged draft stays unapplied until the bottom bar's Apply — closing
/// or reverting restores the active configuration.
struct SettingsView: View {
    @ObservedObject var server: ServerManager
    @StateObject var editor: SettingsEditor
    @State var deleteLogsDisabled = false
    @State var logDeletionError = ""
    @State var windowFitter = SettingsWindowFitter()
    /// Each pane's last measured content height; see `fitted(_:)`.
    @State var paneContentHeight: [SettingsPane: CGFloat] = [:]
    @State var validationMessages = SettingsValidationMessages()
    @State var isSettingsVisible = false
    /// Whether the user opened or closed the sampling values; nil leaves it to what is set.
    @State var samplingOpen: Bool?
    @StateObject private var paneSelection = SettingsPaneSelection()
    var selectedPaneRaw: String {
        get { paneSelection.rawValue }
        nonmutating set { paneSelection.rawValue = newValue }
    }

    init(server: ServerManager) {
        _server = ObservedObject(wrappedValue: server)
        _editor = StateObject(wrappedValue: SettingsEditor(server: server))
    }

    var draft: ServerConfiguration.Config {
        get { editor.draft }
        nonmutating set { editor.draft = newValue }
    }
    var derived: SplashDerivedState {
        get { editor.derived }
        nonmutating set { editor.derived = newValue }
    }
    var derivedInputs: SettingsDerivedInputs {
        get { editor.derivedInputs }
        nonmutating set { editor.derivedInputs = newValue }
    }
    var derivedRefreshRevision: Int {
        get { editor.derivedRefreshRevision }
        nonmutating set { editor.derivedRefreshRevision = newValue }
    }
    var completedDerivedRefreshRevision: Int {
        get { editor.completedDerivedRefreshRevision }
        nonmutating set { editor.completedDerivedRefreshRevision = newValue }
    }
    var validationErrors: [ServerConfiguration.Config.Field: String] {
        get { editor.validationErrors }
        nonmutating set { editor.validationErrors = newValue }
    }
    var applyValidationID: UUID? {
        get { editor.applyValidationID }
        nonmutating set { editor.applyValidationID = newValue }
    }
    var isApplyingSettings: Bool {
        get { editor.isApplyingSettings }
        nonmutating set { editor.isApplyingSettings = newValue }
    }
    var isRefreshingDerivedState: Bool {
        get { editor.isRefreshingDerivedState }
        nonmutating set { editor.isRefreshingDerivedState = newValue }
    }
    var logNameText: String {
        get { editor.logNameText }
        nonmutating set { editor.logNameText = newValue }
    }
    var statusNotice: String {
        get { editor.statusNotice }
        nonmutating set { editor.statusNotice = newValue }
    }
    var statusNoticeIsFailure: Bool {
        get { editor.statusNoticeIsFailure }
        nonmutating set { editor.statusNoticeIsFailure = newValue }
    }
    var settledFamily: String? {
        get { editor.settledFamily }
        nonmutating set { editor.settledFamily = newValue }
    }
    var draftFamily: String? { editor.draftFamily }
    func restoreActiveDraft(refreshDerived: Bool) { editor.restoreActiveDraft(refreshDerived: refreshDerived) }
    func showNotice(_ text: String, isFailure: Bool = false) { editor.showNotice(text, isFailure: isFailure) }
    func requestDerivedRefresh() { editor.requestDerivedRefresh() }
    func fileNameError() -> String? { editor.fileNameError() }
    func settingsValidationErrors(for config: ServerConfiguration.Config, derived: SplashDerivedState? = nil) -> [ServerConfiguration.Config.Field: String] {
        editor.settingsValidationErrors(for: config, derived: derived)
    }
    func refreshDerivedStateAfterEditing(for config: ServerConfiguration.Config, refreshRevision: Int) async {
        await editor.refreshDerivedStateAfterEditing(for: config, refreshRevision: refreshRevision)
    }
    func applyPickedPath(_ field: SettingsPathField, path: String) { editor.applyPickedPath(field, path: path) }
    func logNameDidChange() { editor.logNameDidChange() }
    func applySettings() { editor.applySettings() }
    func settleFamily() async { await editor.settleFamily() }

    // MARK: Header

    /// What the notice line says: the Apply in progress, else the last notice.
    private var noticeText: String {
        isApplyingSettings ? "Checking selected files…" : statusNotice
    }

    /// Two lines, always, so a notice appearing or leaving never moves a
    /// control below it (a row can slide out from under a click already on its
    /// way). The hidden sizer fixes the height; there is no text to reserve
    /// lines on when nothing is showing.
    ///
    /// - No notice: the server status, which wraps onto the second line.
    /// - A notice that fits one line: the status on line 1, the notice on 2.
    /// - A longer notice: it starts on line 1, in place of the status, and
    ///   wraps onto line 2.
    ///
    /// What still does not fit truncates. Both texts are in their tooltips and
    /// copy from their context menus.
    private var settingsHeader: some View {
        ZStack(alignment: .topLeading) {
            Text("A\nA")
                .lineLimit(2, reservesSpace: true)
                .hidden()
                .accessibilityHidden(true)
            if noticeText.isEmpty {
                statusLine(limit: 2)
            } else {
                ViewThatFits(in: .horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        // The placeholder carries the line's height and the full
                        // width; the status itself is an overlay, so its length
                        // does not decide which of these two layouts fits.
                        Text("A")
                            .hidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(alignment: .topLeading) { statusLine(limit: 1) }
                        noticeLine(limit: 1)
                    }
                    noticeLine(limit: 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func statusLine(limit: Int) -> some View {
        Text("Server status: \(Text(server.statusText).foregroundStyle(server.statusColor))")
            .lineLimit(limit)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("Server status: \(server.statusText)")
            .contextMenu {
                Button("Copy Status") { copyText(server.statusText) }
            }
    }

    private func noticeLine(limit: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if isApplyingSettings {
                ProgressView()
                    .controlSize(.small)
            } else if statusNoticeIsFailure {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            Text(noticeText)
                .font(.callout)
                .fontWeight(statusNoticeIsFailure ? .medium : .regular)
                .foregroundStyle(statusNoticeIsFailure ? Color.red : Color.secondary)
                .lineLimit(limit)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .help(noticeText)
        .contextMenu {
            Button("Copy Message") { copyText(noticeText) }
        }
        .accessibilityElement(children: .combine)
    }

    var activePane: SettingsPane {
        SettingsPane(rawValue: selectedPaneRaw) ?? .general
    }

    var hasChanges: Bool {
        editor.candidate(from: draft) != server.configurationSnapshot()
    }

    var canApply: Bool {
        hasChanges && !server.isQuitting && !isApplyingSettings && fileNameError() == nil
    }

    var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { draft.launchAtLogin },
            set: { requested in
                let update = server.setLaunchAtLogin(requested)
                editor.updateLoginPreference(update.isEnabled)
                showNotice(update.warning ?? (
                    update.isEnabled ? "Launch at login enabled." : "Launch at login disabled."
                ), isFailure: update.warning != nil)
            }
        )
    }

    var performanceDisplayBinding: Binding<Bool> {
        Binding(
            get: { server.showsPerformanceInMenuBar },
            set: { server.setShowsPerformanceInMenuBar($0) }
        )
    }

    var keepAwakeBinding: Binding<Bool> {
        Binding(
            get: { server.keepsAwakeWhileRunning },
            set: { server.setKeepsAwakeWhileRunning($0) }
        )
    }

    var quitConfirmationBinding: Binding<Bool> {
        Binding(
            get: { server.confirmQuitWhileServerActive },
            set: { server.setConfirmQuitWhileServerActive($0) }
        )
    }

    var autoRestartBinding: Binding<Bool> {
        Binding(
            get: { server.autoRestartServer },
            set: { server.setAutoRestartServer($0) }
        )
    }

    var applyTitle: String {
        switch server.status {
        case .starting, .running, .restarting:
            return "Apply & Restart"
        case .stopped, .stopping, .error:
            return "Apply"
        }
    }

    /// Says what did not happen, not just what to do about it. A running
    /// server stays green while a refused apply changes nothing, so the notice
    /// has to rule out the reading that it took effect.
    var body: some View {
        activePaneContent
        .formStyle(.grouped)
        .navigationTitle(activePane.title)
        .safeAreaInset(edge: .top, spacing: 0) {
            settingsHeader
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(.thinMaterial)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actionBar
        }
        // Outside the bars: a width on the panes alone leaves the bars, and
        // with them the window, free to widen around a centered Form.
        .frame(width: 640)
        .background(SettingsWindowSizer(fitter: windowFitter))
        .onChange(of: draft) { _, newValue in
            let inputs = SettingsDerivedInputs(newValue)
            let errors = settingsValidationErrors(for: newValue)
            if errors != validationErrors {
                validationErrors = errors
            }
            // A refusal names settings to fix and an Apply to press. Once
            // nothing is highlighted, or the draft matches what is already
            // running, it is telling the user to do something that is no
            // longer there.
            if statusNoticeIsFailure,
               errors.isEmpty || editor.candidate(from: newValue) == server.configurationSnapshot() {
                showNotice("")
            }
            isRefreshingDerivedState = inputs != derivedInputs ||
                derivedRefreshRevision != completedDerivedRefreshRevision
        }
        .onChange(of: editor.selectedPaneRaw) { _, pane in selectedPaneRaw = pane }
        .task(id: draftFamily) { await settleFamily() }
        .onChange(of: selectedPaneRaw) { _, pane in
            editor.selectedPaneRaw = pane
            // A pane whose content is unchanged since it was last shown
            // reports nothing on its return, so fit from what it reported
            // then. A pane that does report has already run by the next
            // runloop turn and left its current height here.
            fitWindow(to: activePane)
        }
        .onChange(of: validationMessages) { _, _ in
            fitWindow(to: activePane)
        }
        .task(id: DerivedTaskID(
            inputs: SettingsDerivedInputs(draft),
            refreshRevision: derivedRefreshRevision
        )) {
            await refreshDerivedStateAfterEditing(
                for: draft,
                refreshRevision: derivedRefreshRevision
            )
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            guard isSettingsVisible else { return }
            requestDerivedRefresh()
        }
        .task(id: deleteLogsDisabled) {
            guard deleteLogsDisabled else { return }
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
            deleteLogsDisabled = false
        }
        .alert("Unable to Delete Logs", isPresented: Binding(
            get: { !logDeletionError.isEmpty },
            set: { if !$0 { logDeletionError = "" } }
        )) {
            Button("OK") { logDeletionError = "" }
        } message: {
            Text(logDeletionError)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: SettingsNavigation.destinationNotification
        )) { notification in
            guard let rawValue = notification.object as? String,
                  let destination = ServerSettingsDestination(rawValue: rawValue)
            else { return }
            selectedPaneRaw = destination.rawValue
            UserDefaults.standard.removeObject(forKey: SettingsNavigation.pendingPaneKey)
        }
        // Closing Settings without applying is equivalent to cancelling a draft,
        // so the next opening starts from the active configuration. Both hooks
        // are wired: the view is long-lived, and a Settings window that is closed
        // rather than destroyed does not reliably deliver onDisappear.
        .onAppear {
            isSettingsVisible = true
            resetDraft()
        }
        .onDisappear {
            isSettingsVisible = false
            resetDraft(refreshDerived: false)
        }
    }

    /// Identifies the inspection a task belongs to, so a new edit cancels the
    /// one in flight.
    struct DerivedTaskID: Hashable {
        let inputs: SettingsDerivedInputs
        let refreshRevision: Int
    }

    func resetDraft(refreshDerived: Bool = true) {
        restoreActiveDraft(refreshDerived: refreshDerived)
        if let destination = SettingsNavigation.consumePendingPane() {
            selectedPaneRaw = destination.rawValue
        }
        editor.selectedPaneRaw = selectedPaneRaw
    }

    /// Staged edits act from here: one prominent Apply with Revert beside it.
    /// The bar is always present and pinned, so it stays reachable no matter
    /// how long the pane is or how far it has been scrolled; both buttons are
    /// disabled until the draft differs from the running configuration.
    var actionBar: some View {
        HStack(spacing: 12) {
            if hasChanges {
                // Return only reaches Apply while Apply is enabled.
                Text(canApply ? "Return to apply \u{2022} Esc to revert" : "Esc to revert")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Revert") {
                restoreActiveDraft(refreshDerived: true)
            }
            .keyboardShortcut(.cancelAction)
            .disabled(!hasChanges)
            Button(applyTitle, action: applySettings)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// A `TabView` inside a `Settings` scene is what draws the window's
    /// noncustomizable pane toolbar, with the icon-over-label items and the
    /// selected-pane highlight that Finder and Safari settings use.
    /// Selection goes through `activePane`, so a stored value that names no
    /// pane selects General in the tabs as well as the title.
    var activePaneContent: some View {
        TabView(selection: Binding(
            get: { activePane },
            set: { selectedPaneRaw = $0.rawValue }
        )) {
            fitted(.general) { generalPane }
                .tabItem { paneLabel(.general) }
                .tag(SettingsPane.general)
            fitted(.model) { modelPane }
                .tabItem { paneLabel(.model) }
                .tag(SettingsPane.model)
            fitted(.server) { serverPane }
                .tabItem { paneLabel(.server) }
                .tag(SettingsPane.server)
            fitted(.memory) { memoryPane }
                .tabItem { paneLabel(.memory) }
                .tag(SettingsPane.memory)
            fitted(.cache) { cachePane }
                .tabItem { paneLabel(.cache) }
                .tag(SettingsPane.cache)
            fitted(.api) { apiPane }
                .tabItem { paneLabel(.api) }
                .tag(SettingsPane.api)
            fitted(.requests) { requestsPane }
                .tabItem { paneLabel(.requests) }
                .tag(SettingsPane.requests)
            fitted(.diagnostics) { diagnosticsPane }
                .tabItem { paneLabel(.diagnostics) }
                .tag(SettingsPane.diagnostics)
        }
    }

    func paneLabel(_ pane: SettingsPane) -> some View {
        Label(pane.title, systemImage: pane.systemImage)
    }

    /// Reports the pane's content height to the window fitter whenever it
    /// changes. The window fits the pane less its validation messages: a typo
    /// should not move the action bar, so a message scrolls the pane and the
    /// scroll bar leaves once the field is corrected. Rows that appear or
    /// leave with a message still resize the window.
    func fitted<Pane: View>(
        _ pane: SettingsPane,
        @ViewBuilder content: () -> Pane
    ) -> some View {
        content()
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height
            } action: { _, height in
                paneContentHeight[pane] = height
                guard pane == activePane else { return }
                fitWindow(to: pane)
            }
    }

    func fitWindow(to pane: SettingsPane) {
        windowFitter.fitAfterLayout {
            guard let height = paneContentHeight[pane] else { return nil }
            return height - validationMessages.height(in: pane)
        }
    }

    // MARK: Paths

    func choosePath(field: SettingsPathField) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !field.choosesDirectory
        panel.canChooseDirectories = field.choosesDirectory || field.choosesFileOrDirectory
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = field.choosesDirectory
        // The log and cache folders default inside ~/Library, which Finder
        // does not list, so the panel has to show them.
        panel.showsHiddenFiles = field == .cacheDirectory || field == .logDirectory
        if field == .visionProjector || field == .model,
           let ggufType = UTType(filenameExtension: "gguf", conformingTo: .data) {
            panel.allowedContentTypes = field == .model ? [ggufType, .folder] : [ggufType]
        }
        if let startDirectory = panelStartDirectory(for: field) {
            panel.directoryURL = startDirectory
        }

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        applyPickedPath(field, path: url.path)
    }

    /// Open the panel where the current selection lives. A configured folder
    /// that has yet to be created falls back to its nearest existing parent
    /// rather than dropping the user somewhere unrelated.
    func panelStartDirectory(for field: SettingsPathField) -> URL? {
        let current = PathText.expandingTilde(storedPath(for: field))
        guard !current.isEmpty else { return nil }
        var candidate = field.choosesDirectory
            ? current
            : (current as NSString).deletingLastPathComponent
        while !candidate.isEmpty, candidate != "/" {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return URL(fileURLWithPath: candidate)
            }
            candidate = (candidate as NSString).deletingLastPathComponent
        }
        return nil
    }

    func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyCommandPreview() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            SplashCommand.preview(configuration: editor.candidate(from: draft)),
            forType: .string
        )
    }

    /// Copy what a terminal would accept, not the compact form the row shows.
    func copyPath(for field: SettingsPathField) {
        let resolved = PathText.expandingTilde(storedPath(for: field))
        guard !resolved.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resolved, forType: .string)
    }

    func storedPath(for field: SettingsPathField) -> String {
        switch field {
        case .splash: return draft.splashPath
        case .model: return draft.modelPath
        case .visionProjector: return draft.visionProjectorPath
        case .draft: return draft.draftModel
        case .chatTemplate: return draft.chatTemplatePath
        case .cacheDirectory: return draft.cacheDirectory
        case .logDirectory: return PathText.directory(of: draft.logPath)
        }
    }

    func deleteLogs() {
        do {
            try server.clearLog()
            deleteLogsDisabled = true
        } catch {
            logDeletionError = error.localizedDescription
        }
    }
}
