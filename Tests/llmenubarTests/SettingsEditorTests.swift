// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest
@testable import llmenubar

@MainActor
final class SettingsEditorTests: XCTestCase {
    func testSelectedPaneSurvivesSettingsSceneRecreation() {
        let suite = "settings-pane-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = SettingsPaneSelection(defaults: defaults)
        XCTAssertEqual(first.rawValue, SettingsPane.general.rawValue)
        first.rawValue = SettingsPane.memory.rawValue
        let reopened = SettingsPaneSelection(defaults: defaults)
        XCTAssertEqual(reopened.rawValue, SettingsPane.memory.rawValue)
        reopened.rawValue = SettingsPane.diagnostics.rawValue
        XCTAssertEqual(SettingsPaneSelection(defaults: defaults).rawValue, SettingsPane.diagnostics.rawValue)
    }

    private actor Inspection {
        var continuation: CheckedContinuation<SplashDerivedState, Never>?
        func inspect() async -> SplashDerivedState {
            await withCheckedContinuation { continuation = $0 }
        }
        var waiting: Bool { continuation != nil }
        func finish() { continuation?.resume(returning: .uninspected); continuation = nil }
    }
    private func manager() -> ServerManager {
        let suite = "editor-tests-\(UUID())"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let config = ServerConfiguration(defaults: UserDefaults(suiteName: suite)!)
        var value = config.snapshot()
        value.splashPath = "/bin/sh"
        value.huggingFaceModel = "owner/model"
        config.replace(with: value)
        return ServerManager(config: config, notificationSink: { _, _ in })
    }
    private func waitForInspection(_ inspection: Inspection) async {
        for _ in 0..<1000 {
            if await inspection.waiting { return }
            await Task.yield()
        }
        XCTFail("inspection did not start")
    }
    private func settle() async { for _ in 0..<100 { await Task.yield() } }

    func testClosingDraftRejectsPendingApply() async {
        let server = manager(), inspection = Inspection()
        let editor = SettingsEditor(server: server, inspect: { _ in await inspection.inspect() })
        editor.draft.maxContext = "128K"
        editor.applySettings()
        await waitForInspection(inspection)
        editor.restoreActiveDraft(refreshDerived: false)
        await inspection.finish()
        await settle()
        XCTAssertEqual(server.configurationSnapshot().maxContext, "")
        XCTAssertFalse(editor.isApplyingSettings)
    }

    func testEditDuringApplyRejectsOlderCandidate() async {
        let server = manager(), inspection = Inspection()
        let editor = SettingsEditor(server: server, inspect: { _ in await inspection.inspect() })
        editor.draft.maxContext = "128K"
        editor.applySettings()
        await waitForInspection(inspection)
        editor.draft.maxContext = "64K"
        await inspection.finish()
        await settle()
        XCTAssertEqual(server.configurationSnapshot().maxContext, "")
        XCTAssertTrue(editor.statusNoticeIsFailure)
        XCTAssertEqual(editor.draft.maxContext, "64K")
    }

    func testChangedBaselineCannotBeOverwritten() async {
        let server = manager()
        let editor = SettingsEditor(server: server, inspect: { _ in .uninspected })
        editor.draft.maxContext = "128K"
        var replacement = server.configurationSnapshot()
        replacement.port = 18992
        server.config.replace(with: replacement)
        editor.applySettings()
        await settle()
        XCTAssertEqual(server.configurationSnapshot().port, 18992)
        XCTAssertEqual(server.configurationSnapshot().maxContext, "")
        XCTAssertTrue(editor.statusNoticeIsFailure)
    }
}
