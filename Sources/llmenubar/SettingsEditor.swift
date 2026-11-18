// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation
import Combine

/// Owns draft edits and asynchronous validation; views own layout and panels.
@MainActor
final class SettingsEditor: ObservableObject {
    typealias Inspector = @Sendable (ServerConfiguration.Config) async -> SplashDerivedState
    private let inspect: Inspector
    let server: ServerManager
    private(set) var baseline: ServerConfiguration.Config
    @Published var selectedPaneRaw = SettingsPane.general.rawValue
    @Published var draft: ServerConfiguration.Config
    @Published var derived: SplashDerivedState
    @Published var derivedInputs: SettingsDerivedInputs
    @Published var derivedRefreshRevision = 0
    @Published var completedDerivedRefreshRevision = 0
    @Published var validationErrors: [ServerConfiguration.Config.Field: String]
    @Published var applyValidationID: UUID?
    @Published var isApplyingSettings = false
    @Published var isRefreshingDerivedState = false
    @Published var logNameText: String
    @Published var statusNotice = ""
    @Published var statusNoticeIsFailure = false
    @Published var settledFamily: String?

    init(server: ServerManager, inspect: @escaping Inspector = { candidate in
        await Task.detached(priority: .userInitiated) { SplashDerivedState.compute(for: candidate) }.value
    }) {
        self.inspect = inspect
        self.server = server
        let snapshot = server.configurationSnapshot()
        baseline = snapshot
        draft = snapshot
        settledFamily = ModelFamily.key(of: snapshot)
        derived = .uninspected
        derivedInputs = SettingsDerivedInputs(snapshot)
        validationErrors = snapshot.validationErrors()
        logNameText = PathText.fileName(of: snapshot.logPath)
    }
    func updateLoginPreference(_ enabled: Bool) {
        baseline.launchAtLogin = enabled
        draft.launchAtLogin = enabled
    }

    func restoreActiveDraft(refreshDerived: Bool) {
        let snapshot = server.configurationSnapshot()
        baseline = snapshot
        draft = snapshot
        settledFamily = ModelFamily.key(of: snapshot)
        logNameText = PathText.fileName(of: snapshot.logPath)
        applyValidationID = nil
        isApplyingSettings = false
        validationErrors = settingsValidationErrors(for: snapshot)
        if refreshDerived {
            requestDerivedRefresh()
        } else {
            isRefreshingDerivedState = false
        }
        showNotice("")
    }

    /// One place sets both halves of the notice, so a failure can never keep
    /// the informational styling of whatever was shown before it.
    func showNotice(_ text: String, isFailure: Bool = false) {
        statusNotice = text
        statusNoticeIsFailure = isFailure && !text.isEmpty
    }

    func requestDerivedRefresh() {
        isRefreshingDerivedState = true
        derivedRefreshRevision &+= 1
    }

    func settingsValidationErrors(
        for config: ServerConfiguration.Config,
        derived override: SplashDerivedState? = nil
    ) -> [ServerConfiguration.Config.Field: String] {
        var errors = config.normalized().validationErrors(derived: override ?? derived)
        if let error = fileNameError() {
            errors[.logPath] = error
        }
        return errors
    }

    /// A name the app will turn into a file it creates, so it has to be one
    /// path component. The draft keeps the last usable value while the field
    /// says why the current text is not one.
    func fileNameError() -> String? {
        let text = logNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "." || text == ".." {
            return "Enter a file name"
        }
        if text.contains("/") {
            return "A file name cannot contain a slash"
        }
        return nil
    }

    func refreshDerivedStateAfterEditing(
        for config: ServerConfiguration.Config,
        refreshRevision: Int
    ) async {
        let inputs = SettingsDerivedInputs(config)
        let forceRefresh = refreshRevision != completedDerivedRefreshRevision
        guard inputs != derivedInputs || forceRefresh else {
            isRefreshingDerivedState = false
            return
        }

        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        guard !isApplyingSettings else {
            isRefreshingDerivedState = false
            return
        }

        let candidate = config.normalized()
        let result = await inspect(candidate)

        guard !Task.isCancelled,
              SettingsDerivedInputs(draft) == inputs,
              derivedRefreshRevision == refreshRevision
        else { return }

        derived = result
        derivedInputs = inputs
        completedDerivedRefreshRevision = refreshRevision
        validationErrors = settingsValidationErrors(for: draft, derived: result)
        isRefreshingDerivedState = false
    }

    func applyPickedPath(_ field: SettingsPathField, path: String) {
        if isApplyingSettings {
            applyValidationID = nil
            isApplyingSettings = false
        }
        let stored = PathText.storingAbsolute(path)
        switch field {
        case .splash: draft.splashPath = stored
        case .model: draft.modelPath = stored
        case .visionProjector: draft.visionProjectorPath = stored
        case .draft: draft.draftModel = stored
        case .chatTemplate: draft.chatTemplatePath = stored
        case .cacheDirectory: draft.cacheDirectory = stored
        case .logDirectory:
            draft.logPath = PathText.storingFile(directory: stored, name: logNameText)
        }
        if field != .cacheDirectory, field != .logDirectory {
            requestDerivedRefresh()
        }
    }

    func logNameDidChange() {
        if isApplyingSettings {
            applyValidationID = nil
            isApplyingSettings = false
        }
        // Hold the draft at its last usable value while the text is not a
        // name, so Apply can never write a path built from a rejected one.
        if fileNameError() == nil {
            draft.logPath = PathText.storingFile(
                directory: PathText.directory(of: draft.logPath),
                name: logNameText
            )
        }
        validationErrors = settingsValidationErrors(for: draft)
    }

    // MARK: Apply

    func applySettings() {
        guard !isApplyingSettings else { return }
        let candidate = draft.normalized()
        let previous = baseline
        let validationID = UUID()
        applyValidationID = validationID
        isApplyingSettings = true
        showNotice("")

        Task { [self] in
            let checked = await inspect(candidate)

            guard applyValidationID == validationID, draft.normalized() == candidate else {
                // Picking a path or editing a file name already cancelled this
                // pass. Anything else means another control moved while the
                // checks ran, and the click needs to say so rather than look
                // like it did nothing.
                if applyValidationID == validationID {
                    applyValidationID = nil
                    isApplyingSettings = false
                    showNotice(
                        "Settings changed while the files were checked. Apply again.",
                        isFailure: true
                    )
                }
                return
            }

            let errors = settingsValidationErrors(for: candidate, derived: checked)
            derived = checked
            derivedInputs = SettingsDerivedInputs(candidate)
            completedDerivedRefreshRevision = derivedRefreshRevision
            validationErrors = errors
            applyValidationID = nil
            isApplyingSettings = false

            guard errors.isEmpty else {
                revealFirstValidationError(in: errors)
                showNotice(applyRefusedNotice, isFailure: true)
                return
            }
            finishApplying(candidate, derived: checked, previous: previous)
        }
    }

    /// Move to the pane holding the first field that refused the draft. The
    /// order matches `firstValidationError`, so the pane shown is the one
    /// naming the error a launch would report first. Returns false when the
    /// refusal has no field to show.
    @discardableResult
    func revealFirstValidationError(
        in errors: [ServerConfiguration.Config.Field: String]
    ) -> Bool {
        guard let field = ServerConfiguration.Config.Field.allCases.first(where: {
            errors[$0] != nil
        }) else { return false }
        selectedPaneRaw = SettingsPane.containing(field).rawValue
        return true
    }

    func finishApplying(
        _ config: ServerConfiguration.Config,
        derived: SplashDerivedState,
        previous: ServerConfiguration.Config
    ) {
        // Report what the manager actually did — a .starting status whose
        // process never came up is applied, not restarted.
        let result = server.applyConfiguration(config, derived: derived, previous: previous)
        switch result.kind {
        case .invalid:
            // The manager also refuses an Apply if the applied configuration
            // changed while the files were checked. Otherwise, any validation
            // disagreement should reveal the field that needs attention.
            let errors = settingsValidationErrors(for: config)
            validationErrors = errors
            guard !server.isQuitting else {
                showNotice("Settings not applied. LLMenuBar is quitting.", isFailure: true)
                return
            }
            showNotice(
                revealFirstValidationError(in: errors)
                    ? applyRefusedNotice
                    : "Settings not applied. Review the settings and apply again.",
                isFailure: true
            )
            return
        case .applied, .appliedAndRestarting:
            break
        }
        // Without this the launch-at-login read-back below would flip the toggle
        // back with no explanation of why.
        showNotice(result.warning ?? "", isFailure: result.warning != nil)
        let snapshot = server.configurationSnapshot()
        baseline = snapshot
        draft = snapshot
        settledFamily = ModelFamily.key(of: snapshot)
        logNameText = PathText.fileName(of: snapshot.logPath)
        validationErrors = settingsValidationErrors(for: snapshot)
    }

    /// The family of the model the draft names, while it names one.
    var draftFamily: String? { ModelFamily.key(of: draft) }

    /// Put a family's projector and draft back when the draft's model moves to
    /// another family. A name being typed passes through many families on the
    /// way, so this waits for the name to hold still.
    func settleFamily() async {
        guard let family = draftFamily, family != settledFamily else { return }
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard !Task.isCancelled, family == draftFamily else { return }
        let previous = settledFamily
        settledFamily = family
        guard previous != nil,
              let restoration = server.familyRestoration(for: family, current: draft)
        else { return }
        draft.visionProjectorPath = restoration.visionProjector
        draft.draftModel = restoration.draft
        requestDerivedRefresh()
        showNotice(restoration.message)
    }

    var applyRefusedNotice: String {
        switch server.status {
        case .starting, .running, .restarting:
            return "Settings not applied, server not restarted. "
                + "Fix the highlighted settings, then Apply & Restart."
        case .stopped, .stopping, .error:
            return "Settings not applied. Fix the highlighted settings, then Apply."
        }
    }

}
