// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Darwin
import XCTest

@testable import llmenubar

/// Live orchestration tests. ServerManager owns its collaborators in the app,
/// so these inject a suite-backed configuration, short process graces, a
/// one-second health cadence, a short stability window, and a notification
/// counter. A loopback stub serves the health endpoint; the child process is a
/// script that never binds the port, so the stub owns it.
@MainActor
final class ServerManagerTests: XCTestCase {

    // MARK: - Harness

    private final class NotificationLog {
        private(set) var entries: [(title: String, body: String)] = []

        func record(title: String, body: String) {
            entries.append((title: title, body: body))
        }
    }

    @MainActor
    private final class Harness {
        let manager: ServerManager
        let processManager: ProcessManager
        let stub: LoopbackStubServer
        let notifications = NotificationLog()
        let directory: URL
        let logPath: String
        let readyMarker: URL
        let pidFile: URL
        private let suiteName: String

        init(
            autoRestart: Bool?,
            ignoresSigterm: Bool,
            cleanExitOnSigterm: Bool = false,
            forceKillGrace: TimeInterval,
            portWaitTimeout: TimeInterval,
            stabilityWindow: TimeInterval
        ) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("llmenubar-manager-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            readyMarker = directory.appendingPathComponent("ready")
            pidFile = directory.appendingPathComponent("pid")

            let serverURL = directory.appendingPathComponent("splash")
            let body: String
            if ignoresSigterm {
                body = "trap '' TERM\ntouch '\(readyMarker.path)'\nexec /bin/sleep 60"
            } else if cleanExitOnSigterm {
                // A server that shuts down cleanly on SIGTERM, with status 0.
                body = """
                trap 'exit 0' TERM
                echo $$ > '\(pidFile.path)'
                touch '\(readyMarker.path)'
                while true; do /bin/sleep 0.05; done
                """
            } else {
                body = "exec /bin/sleep 60"
            }
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: serverURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: serverURL.path
            )

            stub = LoopbackStubServer()
            suiteName = "llmenubar-manager-tests-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

            let configuration = ServerConfiguration(defaults: defaults)
            if let autoRestart {
                configuration.setAutoRestartServer(autoRestart)
            }
            var config = ServerConfiguration.Config()
            config.splashPath = serverURL.path
            config.huggingFaceModel = "owner/repo:Q4"
            config.host = "127.0.0.1"
            config.port = Int(stub.port)
            config.logPath = directory.appendingPathComponent("server.log").path
            configuration.replace(with: config)
            logPath = config.logPath

            let notificationLog = notifications
            processManager = ProcessManager(
                forceKillGrace: forceKillGrace,
                portWaitTimeout: portWaitTimeout,
                listenPortAvailable: { _, _ in true } // the independent health stub owns this port
            )
            manager = ServerManager(
                config: configuration,
                processManager: processManager,
                healthChecker: HealthChecker(
                    fastInterval: 1,
                    steadyInterval: 1,
                    stallAdvisoryInterval: 3_600,
                    failureThreshold: 3
                ),
                stabilityWindow: stabilityWindow,
                notificationSink: { title, body in
                    notificationLog.record(title: title, body: body)
                }
            )
        }

        /// Launches recorded in the server log; each launch writes one header.
        func launchCount() -> Int {
            guard let log = try? String(contentsOfFile: logPath, encoding: .utf8) else {
                return 0
            }
            return log.components(separatedBy: "=== llmenubar launch").count - 1
        }

        func shutDown() {
            manager.stop()
            stub.stop()
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Spin the main run loop until `condition` holds or `timeout` elapses; a
    /// blocking wait would deadlock the main-queue work these tests drive.
    private func spin(timeout: TimeInterval = 12, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    private func waitFor(
        _ matches: (ServerStatus) -> Bool,
        on manager: ServerManager,
        timeout: TimeInterval = 12
    ) {
        spin(timeout: timeout) { matches(manager.status) }
    }

    private func isRunning(_ status: ServerStatus) -> Bool {
        if case .running = status { return true }
        return false
    }

    // MARK: - Tests

    func testTheSpeedIsFollowedWhileItIsNotShown() throws {
        let harness = try Harness(autoRestart: nil, ignoresSigterm: false,
                                  forceKillGrace: 1, portWaitTimeout: 0.2,
                                  stabilityWindow: 300)
        defer { harness.shutDown() }
        harness.manager.start()
        waitFor(isRunning, on: harness.manager)
        XCTAssertFalse(harness.manager.showsPerformanceInMenuBar)
        let rate = ServerPerformance(phase: .generation, tokensPerSecond: 42)

        harness.processManager.onPerformanceChange?(rate)
        XCTAssertEqual(harness.manager.performance, rate, "followed before it was ever shown")
        harness.manager.setShowsPerformanceInMenuBar(true)
        XCTAssertEqual(harness.manager.performance, rate)
        harness.manager.setShowsPerformanceInMenuBar(false)
        XCTAssertEqual(harness.manager.performance, rate, "turning it off forgets nothing")
    }

    func testQuitWaitsForForcedExitAndSuppressesRestart() throws {
        let harness = try Harness(autoRestart: nil, ignoresSigterm: true,
                                  forceKillGrace: 0.3, portWaitTimeout: 0.2,
                                  stabilityWindow: 300)
        defer { harness.shutDown() }
        harness.manager.start()
        waitFor(isRunning, on: harness.manager)
        spin { FileManager.default.fileExists(atPath: harness.readyMarker.path) }
        let pid = try XCTUnwrap(harness.processManager.currentPID)
        harness.manager.restart()
        var completions = 0
        harness.manager.quit { completions += 1 }
        harness.manager.quit { completions += 1 }
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(harness.manager.status, .stopping)
        harness.manager.start()
        harness.manager.restart()
        harness.manager.stop()
        spin(timeout: 2) { completions == 2 }
        XCTAssertEqual(completions, 2)
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertFalse(harness.processManager.hasPendingRun)
        XCTAssertEqual(harness.manager.status, .stopped)
        XCTAssertEqual(harness.launchCount(), 1)
        XCTAssertTrue(harness.notifications.entries.isEmpty)
    }

    func testQuitWaitsForResponsiveChildCleanup() throws {
        let harness = try Harness(autoRestart: nil, ignoresSigterm: false,
                                  forceKillGrace: 1, portWaitTimeout: 0.2,
                                  stabilityWindow: 300)
        defer { harness.shutDown() }
        harness.manager.start()
        waitFor(isRunning, on: harness.manager)
        let pid = try XCTUnwrap(harness.processManager.currentPID)
        var completed = false
        harness.manager.quit { completed = true }
        spin(timeout: 2) { completed }
        XCTAssertTrue(completed)
        XCTAssertFalse(harness.processManager.hasPendingRun)
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertEqual(harness.manager.status, .stopped)
    }

    func testStopDuringManualRestartReturnsToStopped() throws {
        let harness = try Harness(autoRestart: nil, ignoresSigterm: true,
                                  forceKillGrace: 0.2, portWaitTimeout: 0.2,
                                  stabilityWindow: 300)
        defer { harness.shutDown() }
        harness.manager.start()
        waitFor(isRunning, on: harness.manager)
        spin { FileManager.default.fileExists(atPath: harness.readyMarker.path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.readyMarker.path))
        harness.manager.restart()
        harness.manager.stop()
        waitFor({ $0 == .stopped }, on: harness.manager, timeout: 2)
        XCTAssertEqual(harness.manager.status, .stopped)
        XCTAssertEqual(harness.launchCount(), 1)
        XCTAssertTrue(harness.notifications.entries.isEmpty)
    }

    /// Apply can change the configured log path under a child still writing to
    /// the old one; Open Log must follow the run.
    func testLogPathFollowsTheRunWhileItLives() throws {
        let harness = try Harness(autoRestart: nil, ignoresSigterm: false,
                                  forceKillGrace: 0.5, portWaitTimeout: 0.5, stabilityWindow: 300)
        defer { harness.shutDown() }
        let configuredElsewhere = harness.directory.appendingPathComponent("elsewhere.log").path
        harness.stub.statusCode = 200
        harness.manager.start()
        waitFor(isRunning, on: harness.manager)
        XCTAssertEqual(harness.manager.logPath, harness.logPath)

        var config = harness.manager.configurationSnapshot()
        config.logPath = configuredElsewhere
        harness.manager.config.replace(with: config)
        XCTAssertEqual(harness.manager.logPath, harness.logPath, "the running child still writes to its own")

        harness.manager.stop()
        waitFor({ $0 == .stopped }, on: harness.manager, timeout: 3)
        XCTAssertEqual(harness.manager.logPath, configuredElsewhere)
    }

    func testUnloadedWeightsShowIdleAndBlankTheSpeed() throws {
        let harness = try Harness(
            autoRestart: nil,
            ignoresSigterm: false,
            forceKillGrace: 0.5,
            portWaitTimeout: 0.5,
            stabilityWindow: 300
        )
        defer { harness.shutDown() }

        harness.stub.statusCode = 200
        harness.manager.start()
        waitFor(isRunning, on: harness.manager)
        guard case .running(let pid) = harness.manager.status else {
            return XCTFail("not running: \(harness.manager.status)")
        }
        harness.manager.setShowsPerformanceInMenuBar(true)
        harness.processManager.onPerformanceChange?(
            ServerPerformance(phase: .generation, tokensPerSecond: 74.2)
        )
        XCTAssertEqual(harness.manager.statusText, "Running (PID \(pid))")
        XCTAssertEqual(harness.manager.performance.menuBarRate, "74.2")

        harness.processManager.onWeightsChange?(.released)
        XCTAssertEqual(harness.manager.statusText, "Idle (PID \(pid)) (unloaded)")
        XCTAssertEqual(harness.manager.performance.menuBarRate, "----")

        harness.processManager.onWeightsChange?(.restored)
        XCTAssertEqual(harness.manager.statusText, "Running (PID \(pid))")
    }

    func testUnresponsiveServerIsRestartedOnce() throws {
        let harness = try Harness(
            autoRestart: nil,
            ignoresSigterm: false,
            forceKillGrace: 0.5,
            portWaitTimeout: 0.5,
            stabilityWindow: 300
        )
        defer { harness.shutDown() }

        harness.stub.statusCode = 200
        harness.manager.start()
        waitFor(isRunning, on: harness.manager)
        XCTAssertTrue(isRunning(harness.manager.status))
        XCTAssertEqual(harness.launchCount(), 1)

        harness.stub.statusCode = 500
        waitFor({ $0 == .stopping }, on: harness.manager)
        XCTAssertEqual(harness.manager.status, .stopping)
        waitFor({ $0 == .restarting }, on: harness.manager)
        XCTAssertEqual(harness.manager.status, .restarting)

        // Answer again before the replacement's polls: one 500 in that run is
        // below the threshold.
        harness.stub.statusCode = 200
        waitFor(isRunning, on: harness.manager)
        XCTAssertTrue(isRunning(harness.manager.status))
        XCTAssertEqual(harness.launchCount(), 2, "exactly one automatic relaunch")
        XCTAssertEqual(harness.notifications.entries.count, 1)
        XCTAssertEqual(harness.notifications.entries.first?.title, "The engine was unresponsive")
        XCTAssertEqual(
            harness.notifications.entries.first?.body.contains("has been restarted"),
            true
        )
    }

    func testSecondFailureInsideTheWindowIsReportedWithoutAnotherRestart() throws {
        let harness = try Harness(
            autoRestart: nil,
            ignoresSigterm: false,
            forceKillGrace: 0.5,
            portWaitTimeout: 0.5,
            stabilityWindow: 300
        )
        defer { harness.shutDown() }

        harness.stub.statusCode = 200
        harness.manager.start()
        waitFor(isRunning, on: harness.manager)

        harness.stub.statusCode = 500
        waitFor({ $0 == .restarting }, on: harness.manager)
        harness.stub.statusCode = 200
        waitFor(isRunning, on: harness.manager)
        XCTAssertEqual(harness.launchCount(), 2)

        // The second failure arrives before a replacement has been healthy for
        // the stability window, so the episode is spent.
        harness.stub.statusCode = 500
        waitFor({ if case .error = $0 { return true }; return false }, on: harness.manager)
        guard case .error(let reason) = harness.manager.status else {
            XCTFail("expected .error")
            return
        }
        XCTAssertTrue(reason.contains("unreachable"), reason)

        spin(timeout: 2) { harness.launchCount() > 2 }
        XCTAssertEqual(harness.launchCount(), 2, "a spent episode must not restart again")
        guard case .error = harness.manager.status else {
            XCTFail("expected .error")
            return
        }
        XCTAssertEqual(harness.notifications.entries.count, 2)
        XCTAssertEqual(
            harness.notifications.entries.last?.body.contains("Automatic restart is not repeating."),
            true
        )
    }

    func testCancellingDuringTheAutoRestartWindowLeavesItStopped() throws {
        let harness = try Harness(
            autoRestart: nil,
            ignoresSigterm: false,
            forceKillGrace: 0.5,
            portWaitTimeout: 2.0,
            stabilityWindow: 300
        )
        defer { harness.shutDown() }

        harness.stub.statusCode = 200
        harness.manager.start()
        waitFor(isRunning, on: harness.manager)

        harness.stub.statusCode = 500
        waitFor({ $0 == .restarting }, on: harness.manager)
        harness.manager.stop()
        XCTAssertEqual(harness.manager.status, .stopped)

        // The port-wait timer is still armed; its callback must be dropped, and
        // the pending restart notice must not survive the cancellation.
        spin(timeout: 3) { harness.launchCount() > 1 }
        XCTAssertEqual(harness.launchCount(), 1)
        XCTAssertEqual(harness.manager.status, .stopped)
        XCTAssertTrue(harness.notifications.entries.isEmpty)
    }

    func testManualStopDuringTheGraceLeavesItStoppedAndSilent() throws {
        let harness = try Harness(
            autoRestart: nil,
            ignoresSigterm: true,
            forceKillGrace: 2.0,
            portWaitTimeout: 0.5,
            stabilityWindow: 300
        )
        defer { harness.shutDown() }

        harness.stub.statusCode = 200
        harness.manager.start()
        waitFor(isRunning, on: harness.manager)

        harness.stub.statusCode = 500
        waitFor({ $0 == .stopping }, on: harness.manager)
        let requestsAtDecision = harness.stub.requestsRead
        harness.manager.stop()
        XCTAssertEqual(harness.manager.status, .stopping, "the frozen child is still alive")

        // Past the grace the forced kill lands; the reaper must call it a user
        // stop: no notification, no relaunch.
        waitFor({ $0 == .stopped }, on: harness.manager, timeout: 6)
        XCTAssertEqual(harness.manager.status, .stopped)
        spin(timeout: 2) { harness.stub.requestsRead > requestsAtDecision }
        XCTAssertEqual(harness.stub.requestsRead, requestsAtDecision, "polling must stay stopped")
        XCTAssertEqual(harness.launchCount(), 1)
        XCTAssertTrue(harness.notifications.entries.isEmpty)
    }

    func testAutoRestartOffReportsAndNeverRelaunches() throws {
        let harness = try Harness(
            autoRestart: false,
            ignoresSigterm: false,
            forceKillGrace: 0.5,
            portWaitTimeout: 0.5,
            stabilityWindow: 300
        )
        defer { harness.shutDown() }

        harness.stub.statusCode = 200
        harness.manager.start()
        waitFor(isRunning, on: harness.manager)

        harness.stub.statusCode = 500
        waitFor({ if case .error = $0 { return true }; return false }, on: harness.manager)
        spin(timeout: 2) { harness.launchCount() > 1 }
        XCTAssertEqual(harness.launchCount(), 1)
        XCTAssertEqual(harness.notifications.entries.count, 1)
        XCTAssertEqual(harness.notifications.entries.first?.title, "The engine stopped")
        XCTAssertEqual(
            harness.notifications.entries.first?.body.contains("Automatic restart is off."),
            true
        )
        XCTAssertEqual(
            harness.notifications.entries.first?.body.contains("not repeating"),
            false,
            "a disabled preference must not claim a spent episode"
        )
    }

    func testAStaleStabilityItemDoesNotClearANewerRunsEpisode() throws {
        let harness = try Harness(
            autoRestart: nil,
            ignoresSigterm: false,
            forceKillGrace: 0.5,
            portWaitTimeout: 0.5,
            stabilityWindow: 8
        )
        defer { harness.shutDown() }

        harness.stub.statusCode = 200
        harness.manager.start()
        waitFor(isRunning, on: harness.manager)
        let firstHealthyAt = Date()

        // First incident restarts automatically into run B.
        harness.stub.statusCode = 500
        waitFor({ $0 == .restarting }, on: harness.manager)
        harness.stub.statusCode = 200
        waitFor(isRunning, on: harness.manager)
        XCTAssertEqual(harness.launchCount(), 2)

        // Let run A's stability item fire while B is still running, before B's
        // own window closes.
        spin(timeout: 12) { Date().timeIntervalSince(firstHealthyAt) >= 8.5 }
        XCTAssertTrue(isRunning(harness.manager.status), "B must still be running when A's item fires")

        harness.stub.statusCode = 500
        waitFor({ if case .error = $0 { return true }; return false }, on: harness.manager)
        spin(timeout: 2) { harness.launchCount() > 2 }
        XCTAssertEqual(harness.launchCount(), 2, "A's stale item must not clear B's episode")
        XCTAssertEqual(harness.notifications.entries.count, 2)
    }

    func testAnExternallyTerminatedServerIsRestarted() throws {
        let harness = try Harness(
            autoRestart: nil,
            ignoresSigterm: false,
            cleanExitOnSigterm: true,
            forceKillGrace: 0.5,
            portWaitTimeout: 0.5,
            stabilityWindow: 300
        )
        defer { harness.shutDown() }

        harness.stub.statusCode = 200
        harness.manager.start()
        waitFor(isRunning, on: harness.manager)

        // The script exits 0 when SIGTERM arrives, which is what Splash
        // does; `pkill` is therefore a clean exit the app did not request.
        spin(timeout: 5) { FileManager.default.fileExists(atPath: harness.pidFile.path) }
        let pidText = try String(contentsOfFile: harness.pidFile.path, encoding: .utf8)
        let pid = try XCTUnwrap(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, SIGTERM), 0)

        // It must be reported and restarted, not silently left stopped.
        waitFor({ $0 == .restarting }, on: harness.manager)
        waitFor(isRunning, on: harness.manager)
        XCTAssertEqual(harness.launchCount(), 2)
        XCTAssertEqual(harness.notifications.entries.count, 1)
        XCTAssertEqual(
            harness.notifications.entries.first?.title,
            "The engine stopped unexpectedly"
        )
        XCTAssertEqual(
            harness.notifications.entries.first?.body.contains("has been restarted"),
            true
        )
    }

    func testAManualStartResetsTheAutoRestartLedger() throws {
        let harness = try Harness(
            autoRestart: nil,
            ignoresSigterm: false,
            forceKillGrace: 0.5,
            portWaitTimeout: 0.5,
            stabilityWindow: 300
        )
        defer { harness.shutDown() }

        // Spend the episode: one automatic restart, then a second failure that
        // is reported instead of repeated.
        harness.stub.statusCode = 200
        harness.manager.start()
        waitFor(isRunning, on: harness.manager)
        harness.stub.statusCode = 500
        waitFor({ $0 == .restarting }, on: harness.manager)
        harness.stub.statusCode = 200
        waitFor(isRunning, on: harness.manager)
        harness.stub.statusCode = 500
        waitFor({ if case .error = $0 { return true }; return false }, on: harness.manager)
        XCTAssertEqual(harness.launchCount(), 2)

        // The hand-started run earns a fresh attempt even though the stability
        // window never elapsed.
        harness.stub.statusCode = 200
        harness.manager.start()
        waitFor(isRunning, on: harness.manager)
        XCTAssertEqual(harness.launchCount(), 3)

        harness.stub.statusCode = 500
        waitFor({ $0 == .restarting }, on: harness.manager)
        harness.stub.statusCode = 200
        waitFor(isRunning, on: harness.manager)
        XCTAssertEqual(harness.launchCount(), 4, "the manual start must clear the ledger")
    }
}
