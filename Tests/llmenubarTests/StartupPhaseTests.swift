// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest
@testable import llmenubar

final class StartupPhaseTests: XCTestCase {
    private let header = """
    === llmenubar launch 2026-11-12 01:31:53 ===
    exec: /opt/homebrew/bin/splash
    argv: serve --model unsloth/Qwen3.8-27B-GGUF:UD-Q6_K --host 127.0.0.1 --port 8000
    ---

    """

    func testNothingWrittenYetIsStarting() {
        XCTAssertEqual(StartupPhase.detect(logTail: ""), .starting)
        XCTAssertEqual(StartupPhase.detect(logTail: header), .starting)
    }

    func testTheFetchLineStartsADownloadAndReportsItsSize() {
        let log = header + "Installing unsloth/Qwen3.8-27B-GGUF:UD-Q6_K as Qwen3.8-27B (gguf).\n"
            + "Fetching 1 file(s), 21.98 GB, from unsloth/Qwen3.8-27B-GGUF@4af51b3542f7; cached files are reused.\n"
        XCTAssertEqual(StartupPhase.detect(logTail: log), .downloading(.init(repository: "unsloth/Qwen3.8-27B-GGUF", totalBytes: 21_980_000_000)))
    }

    func testAProgressBarBelowAHundredPercentIsADownload() {
        let log = header
            + "Fetching 1 file(s), 21.98 GB, from unsloth/Qwen3.8-27B-GGUF@4af51b3542f7; cached files are reused.\n\n"
            + "Fetching 2 files:   0%|          | 0/2 [00:00<?, ?it/s]\r"
            + "Fetching 2 files:  50%|█████     | 1/2 [00:00<00:00,  7.01it/s]"
        XCTAssertEqual(
            StartupPhase.detect(logTail: log),
            .downloading(.init(repository: "unsloth/Qwen3.8-27B-GGUF", totalBytes: 21_980_000_000))
        )
    }

    func testAFinishedBarOrLaterOutputEndsTheDownload() {
        let bar = "Fetching 2 files: 100%|██████████| 2/2 [00:30<00:00, 0.07it/s]"
        XCTAssertEqual(StartupPhase.detect(logTail: header + bar), .starting)
        XCTAssertEqual(
            StartupPhase.detect(logTail: header + "Fetching 2 files:  50%|█████     | 1/2\r" + bar + "\nLoading weights…\n"),
            .starting
        )
    }

    func testAnEarlierLaunchesDownloadDoesNotCount() {
        let earlier = header + "Fetching 1 file(s), 21.98 GB, from x; cached files are reused.\n"
            + "Fetching 2 files:  50%|█████     | 1/2\n"
        let log = earlier + header.replacingOccurrences(of: "01:31:53", with: "02:00:00")
        XCTAssertEqual(StartupPhase.detect(logTail: log), .starting)
    }

    func testAFetchOfFilesAlreadyCachedIsNotADownload() {
        // Small fetches that finish at once leave a completed bar as the last line.
        XCTAssertEqual(
            StartupPhase.detect(logTail: header + "Fetching 2 files: 100%|██████████| 2/2 [00:00<00:00, 2528.97it/s]\n"),
            .starting
        )
    }

    func testStatusWording() {
        XCTAssertNil(StartupPhase.starting.statusText)
        XCTAssertEqual(StartupPhase.downloading(.init()).statusText, "Downloading model…")
        XCTAssertEqual(
            StartupPhase.downloading(.init(totalBytes: 21_980_000_000)).statusText,
            "Downloading model (22 GB)…"
        )
        XCTAssertEqual(
            StartupPhase.downloading(.init(totalBytes: 4_400_000_000)).statusText,
            "Downloading model (4.4 GB)…"
        )
        XCTAssertEqual(
            StartupPhase.downloading(.init(totalBytes: 22_000_000_000, receivedBytes: 9_020_000_000)).statusText,
            "Downloading model: 41% (9.0 of 22 GB)…"
        )
    }

    func testPercentNeedsBothNumbersAndNeverPassesAHundred() {
        XCTAssertNil(StartupPhase.Download(totalBytes: 100, receivedBytes: nil).percent)
        XCTAssertNil(StartupPhase.Download(totalBytes: 100, receivedBytes: 0).percent)
        XCTAssertNil(StartupPhase.Download(totalBytes: nil, receivedBytes: 50).percent)
        XCTAssertEqual(StartupPhase.Download(totalBytes: 100, receivedBytes: 50).percent, 50)
        XCTAssertEqual(StartupPhase.Download(totalBytes: 100, receivedBytes: 500).percent, 100)
    }
}

/// The manager reads a starting engine's output and words the status by it.
@MainActor
final class StartupPhaseManagerTests: XCTestCase {
    private func spin(timeout: TimeInterval, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    func testADownloadIsReportedWhileStartingAndForgottenAfterwards() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-phase-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let splash = directory.appendingPathComponent("splash")
        let script = """
        #!/bin/sh
        echo 'Fetching 1 file(s), 21.98 GB, from unsloth/Qwen3.8-27B-GGUF@4af51b3542f7; cached files are reused.'
        exec /bin/sleep 30
        """
        try Data(script.utf8).write(to: splash)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: splash.path)

        let suite = "llmenubar-manager-tests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let configuration = ServerConfiguration(defaults: defaults)
        var config = ServerConfiguration.Config()
        config.splashPath = splash.path
        config.huggingFaceModel = "unsloth/Qwen3.8-27B-GGUF:UD-Q6_K"
        config.logPath = directory.appendingPathComponent("engine.log").path
        config.port = 62_493
        let cache = directory.appendingPathComponent("hub")
        config.modelCacheDirectory = cache.path
        configuration.replace(with: config)

        let manager = ServerManager(
            config: configuration,
            healthChecker: HealthChecker(fastInterval: 1, steadyInterval: 2),
            notificationSink: { _, _ in }
        )
        defer { manager.stop() }

        XCTAssertEqual(manager.statusText, "Stopped")
        manager.start()
        XCTAssertEqual(manager.status, .starting)
        spin(timeout: 10) { manager.startupPhase.isDownloading }
        XCTAssertEqual(manager.startupPhase.download?.repository, "unsloth/Qwen3.8-27B-GGUF")
        XCTAssertEqual(manager.statusText, "Downloading model (22 GB)…")

        // Bytes that arrive in the cache folder become a percentage.
        let blobs = cache.appendingPathComponent("models--unsloth--Qwen3.8-27B-GGUF/blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let partial = blobs.appendingPathComponent("abc123.x7f.incomplete")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        try handle.truncate(atOffset: 5_495_000_000)
        try handle.close()
        spin(timeout: 6) { manager.statusText.contains("25%") }
        XCTAssertEqual(manager.statusText, "Downloading model: 25% (5.5 of 22 GB)…")

        manager.stop()
        spin(timeout: 10) { manager.status == .stopped }
        XCTAssertEqual(manager.startupPhase, .starting)
        XCTAssertEqual(manager.statusText, "Stopped")
    }

    func testAMalformedSizeIsNoSizeNotATrap() {
        XCTAssertEqual(StartupPhase.bytes(gigabytes: 2.5), 2_500_000_000)
        for bad in [Double.infinity, .nan, -1, 1e300, 9.3e9] {
            XCTAssertNil(StartupPhase.bytes(gigabytes: bad), "\(bad)")
        }
        let digits = String(repeating: "9", count: 400)
        let tail = "=== llmenubar launch x ===\nFetching 3 file(s), \(digits).5 GB, from owner/repo\n"
        guard case .downloading(let download) = StartupPhase.detect(logTail: tail) else {
            return XCTFail("the line is still a download")
        }
        XCTAssertNil(download.totalBytes)
    }
}
