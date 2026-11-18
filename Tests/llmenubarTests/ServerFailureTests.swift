// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest

@testable import llmenubar

@MainActor
final class ServerFailureTests: XCTestCase {
    func testEarlyExitReportsSplashDiagnosticInsteadOfUsageText() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-early-exit-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        // What an argument-parser failure looks like: usage first, and the
        // complaint last.
        let splashURL = directory.appendingPathComponent("splash")
        let script = """
        #!/bin/sh
        echo 'usage: splash serve [-h] --model OWNER/REPO[:VARIANT] [--model-dir PATH]' >&2
        echo '                    [--port PORT] [--host ADDRESS]' >&2
        echo 'splash serve: error: argument --port: port must be between 1 and 65535' >&2
        exit 2
        """
        try Data(script.utf8).write(to: splashURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: splashURL.path)

        let server = ServerManager()
        var configuration = server.configurationSnapshot()
        configuration.splashPath = splashURL.path
        configuration.huggingFaceModel = "owner/repo:Q4"
        configuration.logPath = directory.appendingPathComponent("server.log").path
        configuration.port = 62_491
        server.config.replace(with: configuration)

        let failed = expectation(description: "launch failure reported")
        var failure: ServerLaunchFailure?
        server.onLaunchFailure = {
            failure = $0
            failed.fulfill()
        }

        server.start()
        await fulfillment(of: [failed], timeout: 2)

        let expected = "splash serve: error: argument --port: port must be between 1 and 65535"
        XCTAssertEqual(failure?.message, expected)
        XCTAssertEqual(server.status, .error(expected))
    }

    func testFailureDestinationFollowsCorrectiveSettingsPane() {
        XCTAssertEqual(
            ServerLaunchFailure(
                message: "vision projector not readable at /tmp/mmproj.gguf",
                source: .manual
            ).settingsDestination,
            .model
        )
        XCTAssertEqual(
            ServerLaunchFailure(
                message: "model not found at /tmp/missing.gguf",
                source: .manual
            ).settingsDestination,
            .model
        )
        XCTAssertEqual(
            ServerLaunchFailure(
                message: "[Errno 48] Address already in use",
                source: .manual
            ).settingsDestination,
            .server
        )
        XCTAssertEqual(
            ServerLaunchFailure(
                message: "requires 40 GB of memory but the memory limit is 24 GB",
                source: .manual
            ).settingsDestination,
            .memory
        )
        XCTAssertEqual(
            ServerLaunchFailure(message: "splash not executable", source: .manual).settingsDestination,
            .general
        )
    }

    func testFailureTitlesDistinguishStartAndRestart() {
        let manual = ServerLaunchFailure(message: "bad configuration", source: .manual)

        XCTAssertEqual(manual.notificationTitle, "The engine could not start")
        XCTAssertEqual(ServerLaunchFailure(message: "bad", source: .restart).notificationTitle,
                       "The engine could not restart")
    }

    func testManualStartPublishesOneFailureEvent() {
        let server = ServerManager()
        var configuration = server.configurationSnapshot()
        configuration.splashPath = "/tmp/llmenubar-missing-\(UUID().uuidString)"
        server.config.replace(with: configuration)
        var failures: [ServerLaunchFailure] = []
        server.onLaunchFailure = { failures.append($0) }

        server.start()

        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.source, .manual)
        XCTAssertTrue(failures.first?.message.contains("not found") == true)
    }

    func testNotificationBodyIsTruncatedForLongFailures() {
        let message = String(repeating: "x", count: 300)
        let failure = ServerLaunchFailure(message: message, source: .restart)

        XCTAssertEqual(failure.notificationBody.count, 240)
        XCTAssertTrue(failure.notificationBody.hasSuffix("…"))
    }

    func testOrdinarySettingsDoesNotRequestGeneralPane() {
        defer { UserDefaults.standard.removeObject(forKey: SettingsNavigation.pendingPaneKey) }
        SettingsNavigation.request(.memory)
        SettingsNavigation.open()
        XCTAssertNil(SettingsNavigation.consumePendingPane())
        SettingsNavigation.open(.api)
        XCTAssertEqual(SettingsNavigation.consumePendingPane(), .api)
    }

    func testSettingsNavigationConsumesPendingDestination() {
        UserDefaults.standard.removeObject(forKey: SettingsNavigation.pendingPaneKey)
        XCTAssertNil(SettingsNavigation.consumePendingPane())

        SettingsNavigation.request(.memory)
        XCTAssertEqual(SettingsNavigation.consumePendingPane(), .memory)
        XCTAssertNil(SettingsNavigation.consumePendingPane())
    }

    func testFailuresOfTheNewOptionsOpenThePaneThatSetsThem() {
        let cases: [(message: String, pane: ServerSettingsDestination)] = [
            ("A server already holds the socket /tmp/s.sock. An engine from an earlier session may still be running", .server),
            ("chat template not readable at /tmp/chat.jinja", .model),
            ("the custom chat template serves no request: its prompts for the model do not end with a generation prompt", .model),
            ("Invalid server configuration: This engine has no --cached-states option. Update the engine, or clear this setting.", .memory),
            ("Invalid server configuration: This engine has no --reasoning-effort option. Update the engine, or clear this setting.", .requests),
            ("--default-reasoning-effort (SPLASH_DEFAULT_REASONING_EFFORT) sets the effort of requests that set none", .requests),
        ]
        for (message, pane) in cases {
            XCTAssertEqual(ServerLaunchFailure(message: message, source: .manual).settingsDestination, pane, message)
        }
    }
}
