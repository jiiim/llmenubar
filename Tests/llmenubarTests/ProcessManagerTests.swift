// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation
import XCTest

@testable import llmenubar


/// A configuration that passes validation without any files: a Hugging Face
/// model, and the app's defaults for everything else.
private func validConfig() -> ServerConfiguration.Config {
    var config = ServerConfiguration.Config()
    config.huggingFaceModel = "owner/repo:Q4"
    return config
}

@MainActor
final class ProcessManagerTests: XCTestCase {

    func testRunningProcessRotatesLogAtConfiguredSize() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-live-log-rotate-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let serverURL = directory.appendingPathComponent("splash")
        let script = """
        #!/bin/sh
        /bin/sleep 0.2
        /usr/bin/head -c 1200000 /dev/zero
        exec /bin/sleep 10
        """
        try Data(script.utf8).write(to: serverURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)

        let logURL = directory.appendingPathComponent("server.log")
        let backupURL = directory.appendingPathComponent("server.log.1")

        var configuration = validConfig()
        configuration.splashPath = serverURL.path
        configuration.logPath = logURL.path
        // 5 "MB" of 200,000 bytes: a 1,000,000-byte cap the script's output passes.
        configuration.logMaxSizeMB = 5

        let manager = ProcessManager(bytesPerLogMB: 200_000)
        let terminated = expectation(description: "server terminated")
        manager.onTerminated = { _ in terminated.fulfill() }
        defer {
            if manager.isProcessRunning {
                manager.terminate()
            }
        }

        XCTAssertNotNil(manager.launch(configuration: configuration))
        let deadline = Date().addingTimeInterval(4)
        while !fileManager.fileExists(atPath: backupURL.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }

        XCTAssertTrue(fileManager.fileExists(atPath: backupURL.path))
        XCTAssertLessThanOrEqual(
            (try fileManager.attributesOfItem(atPath: backupURL.path)[.size] as? NSNumber)?
                .intValue ?? .max,
            1_000_000
        )

        manager.terminate()
        await fulfillment(of: [terminated], timeout: 2)
    }

    /// Toggling the menu-bar display must not disturb the running server, and
    /// enabling it mid-request must start at EOF rather than replaying the
    /// history already in the log.
    func testPerformanceMonitoringTogglesAgainstALiveServer() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-live-performance-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let logURL = directory.appendingPathComponent("server.log")
        let stepURL = directory.appendingPathComponent("step")
        let record = "12:00:00 Done · input 10 · cached 0 · output 10 · TTFT 1.0s · "

        // Writes one record per step file the test drops in, so the log grows
        // only when the test says so.
        let serverURL = directory.appendingPathComponent("splash")
        let script = """
        #!/bin/sh
        n=1
        while [ $n -le 3 ]; do
            while [ ! -f '\(stepURL.path)'.$n ]; do /bin/sleep 0.02; done
            echo "\(record)$n.0 tok/s"
            n=$((n + 1))
        done
        exec /bin/sleep 10
        """
        try Data(script.utf8).write(to: serverURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)


        var configuration = validConfig()
        configuration.splashPath = serverURL.path
        configuration.logPath = logURL.path

        let manager = ProcessManager()
        var updates: [ServerPerformance] = []
        manager.onPerformanceChange = { updates.append($0) }
        defer {
            if manager.isProcessRunning {
                manager.terminate()
            }
        }

        // Step 1 lands while monitoring is off and must never be reported, but
        // it still counts as activity: tracking is not gated by the display.
        XCTAssertNotNil(manager.launch(configuration: configuration))
        try await write(step: 1, at: stepURL, awaiting: 1, in: logURL)
        XCTAssertEqual(updates, [])
        try await waitForUsage(manager)
        XCTAssertNotNil(manager.lastUsageAt)

        manager.setPerformanceMonitoring(true)
        try await write(step: 2, at: stepURL, awaiting: 2, in: logURL)
        try await settle()
        XCTAssertEqual(
            updates,
            [ServerPerformance(phase: .generation, tokensPerSecond: 2.0)]
        )

        // Disabling reports idle once and then stays quiet.
        manager.setPerformanceMonitoring(false)
        XCTAssertEqual(updates.last, .idle)
        let afterDisabling = updates.count
        try await write(step: 3, at: stepURL, awaiting: 3, in: logURL)
        try await settle()
        XCTAssertEqual(updates.count, afterDisabling)
        XCTAssertNotNil(manager.lastUsageAt, "tracking must survive disabling the display")
        XCTAssertTrue(manager.isProcessRunning)
    }

    /// Release the server's next record and wait for it to reach the log.
    private func write(
        step: Int,
        at stepURL: URL,
        awaiting records: Int,
        in logURL: URL
    ) async throws {
        try Data().write(to: URL(fileURLWithPath: stepURL.path + ".\(step)"))

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            if log.components(separatedBy: "Done ·").count > records { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Server did not write record \(step)")
    }

    /// Let the write event, the reader's queue hop, and the hop back to main
    /// all drain before asserting.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    /// A launch that lands before the previous run's termination handler must
    /// keep its own log handle and process reference. The handler used to read
    /// `logFileHandle` at fire time and nil `process` unconditionally, so a
    /// superseded run closed the live log and dropped the live child.
    ///
    /// ServerManager cannot reach this sequence — start(source:) refuses while
    /// .stopping — so it is driven against ProcessManager directly.
    func testSupersededTerminationLeavesTheNewRunAlone() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-supersede-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let serverURL = directory.appendingPathComponent("splash")
        // Writes after a delay, so the write lands once the superseded handler
        // has already run: a closed descriptor would lose it.
        let script = """
        #!/bin/sh
        /bin/sleep 0.4
        echo listening
        exec /bin/sleep 30
        """
        try Data(script.utf8).write(to: serverURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)


        func configuration(log: String) -> ServerConfiguration.Config {
            var config = validConfig()
            config.splashPath = serverURL.path
            config.logPath = directory.appendingPathComponent(log).path
            return config
        }
        let configB = configuration(log: "b.log")

        let manager = ProcessManager()
        var terminations = 0
        manager.onTerminated = { _ in terminations += 1 }
        defer {
            if manager.isProcessRunning { manager.terminate() }
        }

        XCTAssertNotNil(manager.launch(configuration: configuration(log: "a.log")))
        let pidA = try XCTUnwrap(manager.currentPID)

        // One main-queue turn: stop, then start again before the first run's
        // termination handler can land.
        manager.terminate()
        XCTAssertNotNil(manager.launch(configuration: configB))
        let pidB = try XCTUnwrap(manager.currentPID)
        XCTAssertNotEqual(pidA, pidB)

        try await Task.sleep(for: .seconds(2))

        XCTAssertTrue(manager.isProcessRunning, "the new run must still be tracked")
        XCTAssertEqual(manager.currentPID, pidB, "the new run's process must not be nilled")

        let log = try String(contentsOfFile: configB.logPath, encoding: .utf8)
        XCTAssertTrue(log.contains("=== llmenubar launch"), "header must reach the new log")
        XCTAssertTrue(
            log.contains("listening"),
            "the new run's log descriptor must stay open for the server's own output"
        )
        XCTAssertEqual(
            terminations, 0,
            "the superseded run must close its own log without reporting a termination"
        )

        // The live run still reports normally when it is the one that ends.
        manager.terminate()
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(manager.isProcessRunning)
        XCTAssertEqual(terminations, 1, "the current run must still report its termination")
    }

    /// A rotation that cannot run is a housekeeping failure, not a launch
    /// failure: the server still starts against the oversized log. It used to
    /// be swallowed by `try?`, which made a broken log directory look like a
    /// server that simply said nothing.
    func testStartupRotationFailureDoesNotStopTheLaunch() throws {
        // root ignores the directory mode this relies on.
        try XCTSkipIf(getuid() == 0, "requires a non-root user")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-rotate-denied-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let logDirectory = directory.appendingPathComponent("logs")
        try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755],
                                           ofItemAtPath: logDirectory.path)
            try? fileManager.removeItem(at: directory)
        }

        let serverURL = directory.appendingPathComponent("splash")
        try Data("#!/bin/sh\nexec /bin/sleep 5\n".utf8).write(to: serverURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)


        // Oversized log left by an earlier run: 2 MB against a 1,000,000-byte cap.
        let logURL = logDirectory.appendingPathComponent("server.log")
        try Data(repeating: 0x41, count: 2 * 1024 * 1024).write(to: logURL)
        // Deny directory writes, so the rotation cannot create its temp file
        // while the existing log stays open for append.
        try fileManager.setAttributes([.posixPermissions: 0o500],
                                      ofItemAtPath: logDirectory.path)

        var config = validConfig()
        config.splashPath = serverURL.path
        config.logPath = logURL.path
        config.logMaxSizeMB = 5

        let manager = ProcessManager(bytesPerLogMB: 200_000)
        defer { if manager.isProcessRunning { manager.terminate() } }

        XCTAssertNotNil(manager.launch(configuration: config),
                        "a denied rotation must not stop the launch")
        XCTAssertTrue(manager.isProcessRunning)
        XCTAssertFalse(
            fileManager.fileExists(atPath: logDirectory.appendingPathComponent("server.log.1").path),
            "rotation was denied, so no backup should exist"
        )
    }

    /// The child is not running at launch, so an oversized log is renamed to
    /// the backup: no copy, however large it is.
    func testStartupRotationRenamesTheOversizedLog() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-rotate-rename-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let serverURL = directory.appendingPathComponent("splash")
        try Data("#!/bin/sh\nexec /bin/sleep 5\n".utf8).write(to: serverURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)
        let log = directory.appendingPathComponent("server.log")
        let backup = directory.appendingPathComponent("server.log.1")
        let big = Data(repeating: 0x41, count: 2_000_000)
        try big.write(to: log)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log.path)
        try Data("older backup".utf8).write(to: backup)
        let inode = try fileManager.attributesOfItem(atPath: log.path)[.systemFileNumber] as? NSNumber

        var config = validConfig()
        config.splashPath = serverURL.path
        config.logPath = log.path
        config.logMaxSizeMB = 5
        let manager = ProcessManager(bytesPerLogMB: 200_000)
        defer { if manager.isProcessRunning { manager.terminate() } }
        XCTAssertNotNil(manager.launch(configuration: config))

        XCTAssertEqual(try Data(contentsOf: backup), big, "the old log is the backup")
        XCTAssertEqual(try fileManager.attributesOfItem(atPath: backup.path)[.systemFileNumber] as? NSNumber,
                       inode, "renamed, not copied")
        XCTAssertEqual(try fileManager.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber, 0o600,
                       "the backup is owner-only whatever mode the old log had")
        let fresh = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(fresh.hasPrefix("=== llmenubar launch"), fresh)
        XCTAssertLessThan(fresh.count, 10_000)
    }

    func testRotateLogRetainsNewestBytesAndKeepsActiveDescriptorValid() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-log-rotate-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let log = directory.appendingPathComponent("server.log")
        let backup = directory.appendingPathComponent("server.log.1")
        try Data("0123456789".utf8).write(to: log)
        try Data("old backup".utf8).write(to: backup)

        let activeFD = open(log.path, O_WRONLY | O_APPEND)
        guard activeFD >= 0 else {
            XCTFail("Unable to open test log")
            return
        }
        let activeWriter = FileHandle(fileDescriptor: activeFD, closeOnDealloc: true)
        defer { try? activeWriter.close() }

        try ProcessManager.rotateLog(
            at: log.path,
            maximumBytes: 6,
            activeFileDescriptor: activeFD
        )
        try activeWriter.write(contentsOf: Data("new output".utf8))

        XCTAssertEqual(String(decoding: try Data(contentsOf: backup), as: UTF8.self), "456789")
        XCTAssertEqual(String(decoding: try Data(contentsOf: log), as: UTF8.self), "new output")
    }

    func testClearLogCollectionTruncatesCurrentLogAndRemovesBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-log-clear-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let log = directory.appendingPathComponent("server.log")
        let backup = directory.appendingPathComponent("server.log.1")
        try Data("current log".utf8).write(to: log)
        try Data("rotated log".utf8).write(to: backup)
        let activeFD = open(log.path, O_WRONLY | O_APPEND)
        guard activeFD >= 0 else {
            XCTFail("Unable to open test log")
            return
        }
        let activeWriter = FileHandle(fileDescriptor: activeFD, closeOnDealloc: true)
        defer { try? activeWriter.close() }

        try ProcessManager().clearLogCollection(logPath: log.path)
        try activeWriter.write(contentsOf: Data("new output".utf8))

        XCTAssertEqual(String(decoding: try Data(contentsOf: log), as: UTF8.self), "new output")
        XCTAssertFalse(fileManager.fileExists(atPath: backup.path))
    }

    func testClearLogCollectionAllowsMissingFiles() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-missing-log-\(UUID().uuidString)")
            .path

        XCTAssertNoThrow(try ProcessManager().clearLogCollection(logPath: path))
    }


    func testRegularFileChecksRejectDirectoriesAndAcceptFileSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-files-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        XCTAssertFalse(fileManager.isReadableRegularFile(atPath: directory.path))
        XCTAssertFalse(fileManager.isExecutableRegularFile(atPath: directory.path))

        let file = directory.appendingPathComponent("model.gguf")
        try Data("model".utf8).write(to: file)
        let link = directory.appendingPathComponent("model-link.gguf")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: file)

        XCTAssertTrue(fileManager.isReadableRegularFile(atPath: file.path))
        XCTAssertTrue(fileManager.isReadableRegularFile(atPath: link.path))
    }

    func testLaunchRejectsAnExecutableDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-server-directory-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        var configuration = validConfig()
        configuration.splashPath = directory.path

        let manager = ProcessManager()
        var failure: String?
        manager.onLaunchFailure = { failure = $0 }

        XCTAssertNil(manager.launch(configuration: configuration))
        XCTAssertEqual(
            failure,
            "splash not found or not executable at \(directory.path)"
        )
    }








    // MARK: - Forced kill

    /// SIGTERM to a stopped or wedged server stays pending, so the forced kill
    /// is what actually ends it.
    func testTerminateForcesAKillWhenSigtermIsIgnored() async throws {
        let server = try makeFakeServer(ignoresSigterm: true, lifetimeSeconds: 60, name: "force-kill")
        defer { try? FileManager.default.removeItem(at: server.directory) }

        let grace: TimeInterval = 0.5
        let manager = ProcessManager(forceKillGrace: grace)
        var info: TerminationInfo?
        let terminated = expectation(description: "the forced kill reports termination")
        manager.onTerminated = { info = $0; terminated.fulfill() }

        XCTAssertNotNil(manager.launch(configuration: configuration(for: server)))
        try await waitForFakeServerReady(server)
        let started = Date()
        manager.terminate()
        await fulfillment(of: [terminated], timeout: 5)

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, grace, "SIGTERM must get its full grace")
        XCTAssertLessThan(elapsed, grace + 2, "the kill must land promptly after the grace")
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.clean, false, "a SIGKILL is not a clean exit")
        XCTAssertFalse(manager.isProcessRunning)
    }

    func testTerminateDoesNotForceKillAServerThatExitsOnSigterm() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-clean-stop-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        // The shell exits 0 when SIGTERM arrives; the sleep loop keeps it alive.
        let serverURL = directory.appendingPathComponent("splash")
        let readyMarker = directory.appendingPathComponent("ready")
        let script = """
        #!/bin/sh
        trap 'exit 0' TERM
        touch '\(readyMarker.path)'
        while true; do /bin/sleep 0.05; done
        """
        try Data(script.utf8).write(to: serverURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)

        var config = validConfig()
        config.splashPath = serverURL.path
        config.logPath = directory.appendingPathComponent("server.log").path

        let manager = ProcessManager(forceKillGrace: 5)
        var info: TerminationInfo?
        let terminated = expectation(description: "termination")
        manager.onTerminated = { info = $0; terminated.fulfill() }
        XCTAssertNotNil(manager.launch(configuration: config))
        let deadline = Date().addingTimeInterval(5)
        while !fileManager.fileExists(atPath: readyMarker.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(
            fileManager.fileExists(atPath: readyMarker.path),
            "the fake server never signalled readiness"
        )

        let started = Date()
        manager.terminate()
        await fulfillment(of: [terminated], timeout: 3)

        XCTAssertLessThan(
            Date().timeIntervalSince(started), 2,
            "a server that exits on SIGTERM must not wait out the grace"
        )
        XCTAssertEqual(info?.clean, true)
    }

    func testRepeatedTerminateDoesNotPostponeTheForcedKill() async throws {
        let server = try makeFakeServer(ignoresSigterm: true, lifetimeSeconds: 60, name: "repeat-terminate")
        defer { try? FileManager.default.removeItem(at: server.directory) }

        let grace: TimeInterval = 1.5
        let manager = ProcessManager(forceKillGrace: grace)
        let terminated = expectation(description: "termination")
        manager.onTerminated = { _ in terminated.fulfill() }
        XCTAssertNotNil(manager.launch(configuration: configuration(for: server)))
        try await waitForFakeServerReady(server)

        let started = Date()
        manager.terminate()
        try await Task.sleep(for: .milliseconds(400))
        // A second terminate must not push the deadline to 0.4 + grace.
        manager.terminate()
        await fulfillment(of: [terminated], timeout: 5)

        XCTAssertLessThan(
            Date().timeIntervalSince(started), grace + 0.4,
            "a repeated terminate must not postpone the kill"
        )
    }

    func testForcedKillForASupersededRunDoesNotTouchItsReplacement() async throws {
        let serverA = try makeFakeServer(ignoresSigterm: true, lifetimeSeconds: 3, name: "supersede-a")
        defer { try? FileManager.default.removeItem(at: serverA.directory) }
        let serverB = try makeFakeServer(ignoresSigterm: false, lifetimeSeconds: 60, name: "supersede-b")
        defer { try? FileManager.default.removeItem(at: serverB.directory) }

        let manager = ProcessManager(forceKillGrace: 0.5)
        XCTAssertNotNil(manager.launch(configuration: configuration(for: serverA)))
        try await waitForFakeServerReady(serverA)
        let pidA = try XCTUnwrap(manager.currentPID)

        // Stop A (arming its forced kill), then hand the manager a new run
        // before that timer can fire.
        manager.terminate()
        XCTAssertNotNil(manager.launch(configuration: configuration(for: serverB)))
        let pidB = try XCTUnwrap(manager.currentPID)
        XCTAssertNotEqual(pidA, pidB)

        try await Task.sleep(for: .seconds(1.5))
        XCTAssertTrue(manager.isProcessRunning)
        XCTAssertEqual(manager.currentPID, pidB, "A's timer must not kill B")
        manager.terminate()
    }

    func testRepeatedStopReportsOneCompletedExit() async throws {
        let server = try makeFakeServer(ignoresSigterm: false, lifetimeSeconds: 60, name: "manual-stop")
        defer { try? FileManager.default.removeItem(at: server.directory) }

        let manager = ProcessManager()
        var info: TerminationInfo?
        let terminated = expectation(description: "termination")
        manager.onTerminated = { info = $0; terminated.fulfill() }
        XCTAssertNotNil(manager.launch(configuration: configuration(for: server)))

        // Repeated stop requests must still report exactly one reaped exit.
        manager.terminate()
        manager.terminate()
        await fulfillment(of: [terminated], timeout: 5)

        XCTAssertFalse(manager.hasPendingRun)
        XCTAssertNotNil(info)
    }

    func testTerminationReportsExitAfterForcedKill() async throws {
        let server = try makeFakeServer(ignoresSigterm: true, lifetimeSeconds: 60, name: "restart-kill")
        defer { try? FileManager.default.removeItem(at: server.directory) }

        let grace: TimeInterval = 0.5
        let manager = ProcessManager(forceKillGrace: grace)
        var info: TerminationInfo?
        let terminated = expectation(description: "termination")
        manager.onTerminated = { info = $0; terminated.fulfill() }
        XCTAssertNotNil(manager.launch(configuration: configuration(for: server)))
        try await waitForFakeServerReady(server)

        let started = Date()
        manager.terminate()
        await fulfillment(of: [terminated], timeout: 5)

        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), grace)
        XCTAssertFalse(manager.hasPendingRun)
        XCTAssertEqual(info?.clean, false)
    }

    // MARK: - Last usage

    func testAServedRequestSetsLastUsage() async throws {
        let server = try makeUsageServer(
            delay: 0.1,
            record: Self.startRecord,
            name: "usage"
        )
        defer { try? FileManager.default.removeItem(at: server.directory) }

        let manager = ProcessManager()
        XCTAssertNil(manager.lastUsageAt)
        XCTAssertNotNil(manager.launch(configuration: server.config))
        defer { if manager.isProcessRunning { manager.terminate() } }

        try await waitForUsage(manager)
        XCTAssertNotNil(manager.lastUsageAt)
    }

    func testRelaunchingClearsLastUsage() async throws {
        let serverA = try makeUsageServer(
            delay: 0.1,
            record: Self.startRecord,
            name: "usage-relaunch-a"
        )
        defer { try? FileManager.default.removeItem(at: serverA.directory) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-usage-relaunch-b-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let serverURL = directory.appendingPathComponent("splash")
        try Data("#!/bin/sh\nexec /bin/sleep 60\n".utf8).write(to: serverURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)
        var configB = validConfig()
        configB.splashPath = serverURL.path
        configB.logPath = directory.appendingPathComponent("server.log").path

        let manager = ProcessManager()
        XCTAssertNotNil(manager.launch(configuration: serverA.config))
        try await waitForUsage(manager)
        XCTAssertNotNil(manager.lastUsageAt)

        manager.terminate()
        let deadline = Date().addingTimeInterval(3)
        while manager.isProcessRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNotNil(manager.launch(configuration: configB))
        defer { if manager.isProcessRunning { manager.terminate() } }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(manager.lastUsageAt, "a new run starts unused")
    }

    func testARequestStartLineCountsAsActivity() async throws {
        let server = try makeUsageServer(
            delay: 0.1,
            record: "12:00:00 Started · input 27291 · cached 0 · effort absent · thinking on",
            name: "usage-prompt-start"
        )
        defer { try? FileManager.default.removeItem(at: server.directory) }

        let manager = ProcessManager()
        XCTAssertNotNil(manager.launch(configuration: server.config))
        defer { if manager.isProcessRunning { manager.terminate() } }

        try await waitForUsage(manager)
        XCTAssertNotNil(manager.lastUsageAt, "a request start with no rate is still activity")
    }

    func testAStaleBatchDoesNotRecordUsage() throws {
        let manager = ProcessManager()
        manager.applyPerformanceBatch(
            ServerLogBatch(updates: [], sawRequestActivity: true),
            monitorID: UUID()
        )
        XCTAssertNil(manager.lastUsageAt, "a batch belonging to no run must be dropped")
    }

    func testAWeightsEventIsReportedOnlyForTheCurrentRun() {
        let manager = ProcessManager()
        var events: [WeightsEvent] = []
        manager.onWeightsChange = { events.append($0) }

        manager.applyPerformanceBatch(ServerLogBatch(weights: .released), monitorID: UUID())
        XCTAssertEqual(events, [], "a batch belonging to no run must be dropped")
        XCTAssertFalse(ServerLogBatch(weights: .released).isEmpty)
    }

    func testAWeightsReleaseLineInTheLogIsReported() async throws {
        let server = try makeUsageServer(
            delay: 0.1,
            record: "03:56:13 Weights released after 600 s without a request; the next request restores them",
            name: "weights-released"
        )
        defer { try? FileManager.default.removeItem(at: server.directory) }

        let manager = ProcessManager()
        var events: [WeightsEvent] = []
        manager.onWeightsChange = { events.append($0) }
        XCTAssertNotNil(manager.launch(configuration: server.config))
        defer { if manager.isProcessRunning { manager.terminate() } }

        let deadline = Date().addingTimeInterval(6)
        while events.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(events, [.released], "reported with the speed display off")
        XCTAssertNil(manager.lastUsageAt, "giving the weights back is not a request")
    }

    func testARecordWrittenJustBeforeStopIsCounted() async throws {
        let server = try makeUsageServer(
            delay: 0,
            record: Self.startRecord,
            name: "usage-stopped"
        )
        defer { try? FileManager.default.removeItem(at: server.directory) }

        let manager = ProcessManager()
        XCTAssertNotNil(manager.launch(configuration: server.config))
        // Wait only until the record is in the file, then stop at once: whether
        // the write event or the stop-time drain consumes it, it must count.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let log = (try? String(contentsOfFile: server.logPath, encoding: .utf8)) ?? ""
            if log.contains("Started ·") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        manager.terminate()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotNil(manager.lastUsageAt)
    }

    private struct UsageServer {
        let directory: URL
        let config: ServerConfiguration.Config
        let logPath: String
    }

    private static let startRecord =
        "12:00:00 Started · input 10 · cached 0 · effort absent · thinking on"

    /// A server that writes one log record after `delay` seconds and then stays
    /// alive, with the GGUF and config a launch needs.
    private func makeUsageServer(
        delay: TimeInterval,
        record: String,
        name: String
    ) throws -> UsageServer {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-\(name)-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let serverURL = directory.appendingPathComponent("splash")
        let logPath = directory.appendingPathComponent("server.log").path
        let script = """
        #!/bin/sh
        /bin/sleep \(delay)
        echo "\(record)"
        exec /bin/sleep 60
        """
        try Data(script.utf8).write(to: serverURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)

        var config = validConfig()
        config.splashPath = serverURL.path
        config.logPath = logPath
        return UsageServer(directory: directory, config: config, logPath: logPath)
    }

    private func waitForUsage(_ manager: ProcessManager, timeout: TimeInterval = 6) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while manager.lastUsageAt == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Fake server helpers

    private struct FakeServer {
        let directory: URL
        let serverURL: URL
        let logPath: String
        /// Written by the script once its signal handling is installed. A
        /// SIGTERM sent before that would kill the shell on its default
        /// disposition, which is what makes the tests race without it.
        let readyMarker: URL
    }

    private func makeFakeServer(
        ignoresSigterm: Bool,
        lifetimeSeconds: Int,
        name: String
    ) throws -> FakeServer {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-\(name)-\(UUID().uuidString)")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let serverURL = directory.appendingPathComponent("splash")
        let readyMarker = directory.appendingPathComponent("ready")
        // `trap ''` sets SIG_IGN, and an ignored signal survives `exec`, so the
        // sleep really does ignore SIGTERM. A normal trap would be replaced
        // before it could run and the forced kill would never be exercised.
        let body = ignoresSigterm
            ? "trap '' TERM\ntouch '\(readyMarker.path)'\nexec /bin/sleep \(lifetimeSeconds)"
            : "exec /bin/sleep \(lifetimeSeconds)"
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: serverURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)


        return FakeServer(
            directory: directory,
            serverURL: serverURL,
            logPath: directory.appendingPathComponent("server.log").path,
            readyMarker: readyMarker
        )
    }

    /// Wait until the fake server has installed its signal handling.
    private func waitForFakeServerReady(_ server: FakeServer) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: server.readyMarker.path),
              Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: server.readyMarker.path),
            "the fake server never signalled readiness"
        )
    }

    private func configuration(for server: FakeServer) -> ServerConfiguration.Config {
        var config = validConfig()
        config.splashPath = server.serverURL.path
        config.logPath = server.logPath
        return config
    }
}
