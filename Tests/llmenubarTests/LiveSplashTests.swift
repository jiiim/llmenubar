// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest

@testable import llmenubar

/// Drives a real `splash serve` through `ServerManager`: start, reach running,
/// serve one request, stop. It loads a model, so it runs only when asked:
///
///     LLMENUBAR_LIVE_SPLASH=/opt/homebrew/bin/splash \
///     LLMENUBAR_LIVE_MODEL=unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M \
///     swift test --filter LiveSplashTests
///
/// The model must already be installed: the launch is offline.
@MainActor
final class LiveSplashTests: XCTestCase {
    @MainActor private final class HTTPResult {
        var status: Int?
        var finished = false
        var value: (Int?, String)?
    }

    private func spin(timeout: TimeInterval, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    func testStartServeOneRequestAndStop() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let splash = environment["LLMENUBAR_LIVE_SPLASH"],
              let model = environment["LLMENUBAR_LIVE_MODEL"]
        else { throw XCTSkip("set LLMENUBAR_LIVE_SPLASH and LLMENUBAR_LIVE_MODEL to run against a real Splash") }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "llmenubar-live-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        let configuration = ServerConfiguration(defaults: defaults)
        var config = ServerConfiguration.Config()
        config.splashPath = splash
        config.huggingFaceModel = model
        config.offline = true
        config.port = 8_791
        config.maxMemory = environment["LLMENUBAR_LIVE_MEMORY"] ?? "24G"
        config.logPath = directory.appendingPathComponent("splash.log").path
        configuration.replace(with: config)
        configuration.setShowsPerformanceInMenuBar(true)

        let derived = SplashDerivedState.compute(for: configuration.snapshot())
        XCTAssertNil(derived.splashIssue)
        XCTAssertTrue(derived.build.isSplash)
        XCTAssertEqual(configuration.snapshot().validationErrors(derived: derived), [:])

        let manager = ServerManager(
            config: configuration,
            healthChecker: HealthChecker(fastInterval: 1, steadyInterval: 2),
            notificationSink: { _, _ in }
        )
        var sawRate: Double?
        let cancellable = manager.$performance.sink { performance in
            if performance.phase == .generation, let rate = performance.tokensPerSecond { sawRate = rate }
        }
        defer {
            cancellable.cancel()
            manager.stop()
        }

        manager.start()
        XCTAssertEqual(manager.status, .starting)
        let startTimeout = TimeInterval(environment["LLMENUBAR_LIVE_TIMEOUT"] ?? "") ?? 240
        spin(timeout: startTimeout) {
            if case .running = manager.status { return true }
            if case .error = manager.status { return true }
            return false
        }
        guard case .running(let pid) = manager.status else {
            let tail = (try? String(contentsOfFile: config.logPath, encoding: .utf8))
                .map { String($0.suffix(3_000)) } ?? "(no log)"
            return XCTFail("did not reach running: \(manager.status)\n--- log tail ---\n\(tail)")
        }
        XCTAssertGreaterThan(pid, 0)

        // One request, so the log has a start and an end line to read.
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8791/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
        {"model":"\(model)","messages":[{"role":"user","content":"Say hi."}],"max_tokens":16,"reasoning_effort":"none"}
        """.utf8)
        let responseState = HTTPResult()
        URLSession.shared.dataTask(with: request) { _, response, _ in
            DispatchQueue.main.async {
                responseState.status = (response as? HTTPURLResponse)?.statusCode
                responseState.finished = true
            }
        }.resume()
        spin(timeout: 60) { responseState.finished }
        XCTAssertEqual(responseState.status, 200)

        spin(timeout: 10) { sawRate != nil && manager.lastServerUsageAt != nil }
        XCTAssertNotNil(sawRate, "the request's generation rate should reach the menu-bar display")
        XCTAssertNotNil(manager.lastServerUsageAt)

        manager.stop()
        XCTAssertEqual(manager.status, .stopping)
        spin(timeout: 30) { manager.status == .stopped }
        XCTAssertEqual(manager.status, .stopped, "an intentional stop must end as Stopped, not as a crash")

        let log = try String(contentsOfFile: config.logPath, encoding: .utf8)
        XCTAssertTrue(log.contains("Ready ·"))
        XCTAssertTrue(log.contains("Done ·"))
    }

    /// The same, for the settings a hand-typed command line carries: local
    /// files with a projector and a draft, a name of the user's own, listening
    /// on every interface, an API key, and an environment variable.
    ///
    ///     LLMENUBAR_LIVE_SPLASH=... LLMENUBAR_LIVE_LOCAL_MODEL=/models/m.gguf \
    ///     LLMENUBAR_LIVE_LOCAL_MMPROJ=/models/mmproj.gguf \
    ///     LLMENUBAR_LIVE_LOCAL_DRAFT=/models/draft-folder \
    ///     swift test --filter LiveSplashTests
    ///
    /// Splash prepares local files by reading each one once, so the first run
    /// on large files takes a while.
    func testLocalFilesWithProjectorKeyAndEnvironment() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let splash = environment["LLMENUBAR_LIVE_SPLASH"],
              let model = environment["LLMENUBAR_LIVE_LOCAL_MODEL"],
              let projector = environment["LLMENUBAR_LIVE_LOCAL_MMPROJ"],
              let draft = environment["LLMENUBAR_LIVE_LOCAL_DRAFT"]
        else { throw XCTSkip("set the LLMENUBAR_LIVE_LOCAL_* variables to run local files against a real Splash") }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-live-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "llmenubar-live-local-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        let key = "llm-live-test-key"
        let name = "local/llmenubar-live"
        var config = ServerConfiguration.Config()
        config.splashPath = splash
        config.modelSource = .local
        config.modelPath = model
        config.localModelName = name
        config.visionProjectorPath = projector
        config.draftModel = draft
        config.offline = true
        config.host = "0.0.0.0"
        config.port = 8_792
        config.apiKey = key
        config.environment = "SPLASH_CRASH_TRACE=1"
        config.maxMemory = environment["LLMENUBAR_LIVE_MEMORY"] ?? "24G"
        config.logPath = directory.appendingPathComponent("splash.log").path
        let configuration = ServerConfiguration(defaults: defaults)
        configuration.replace(with: config)

        let derived = SplashDerivedState.compute(for: configuration.snapshot())
        XCTAssertEqual(configuration.snapshot().validationErrors(derived: derived), [:])

        let manager = ServerManager(
            config: configuration,
            healthChecker: HealthChecker(fastInterval: 1, steadyInterval: 2),
            notificationSink: { _, _ in }
        )
        defer { manager.stop() }

        manager.start()
        let startTimeout = TimeInterval(environment["LLMENUBAR_LIVE_TIMEOUT"] ?? "") ?? 600
        spin(timeout: startTimeout) {
            if case .running = manager.status { return true }
            if case .error = manager.status { return true }
            return false
        }
        guard case .running = manager.status else {
            let tail = (try? String(contentsOfFile: config.logPath, encoding: .utf8))
                .map { String($0.suffix(3_000)) } ?? "(no log)"
            return XCTFail("did not reach running: \(manager.status)\n--- log tail ---\n\(tail)")
        }

        func get(_ path: String, key: String?) -> (status: Int?, body: String) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:8792\(path)")!)
            if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            let result = HTTPResult()
            URLSession.shared.dataTask(with: request) { data, response, _ in
                DispatchQueue.main.async {
                    result.value = ((response as? HTTPURLResponse)?.statusCode, String(decoding: data ?? Data(), as: UTF8.self))
                }
            }.resume()
            spin(timeout: 30) { result.value != nil }
            return result.value ?? (nil, "")
        }

        XCTAssertEqual(get("/health", key: nil).status, 200, "health stays open so the app can watch it")
        XCTAssertEqual(get("/ready", key: nil).status, 200)
        XCTAssertEqual(get("/v1/models", key: nil).status, 401, "the API requires the key")
        XCTAssertEqual(get("/v1/models", key: "wrong").status, 401)
        let models = get("/v1/models", key: key)
        XCTAssertEqual(models.status, 200)
        XCTAssertTrue(models.body.contains("\"\(name)\""), "the model is served under the chosen name")
        XCTAssertTrue(models.body.contains("pdf"), "the projector gives the model image and PDF input")

        manager.stop()
        spin(timeout: 60) { manager.status == .stopped }
        XCTAssertEqual(manager.status, .stopped)

        let log = try String(contentsOfFile: config.logPath, encoding: .utf8)
        XCTAssertFalse(log.contains(key), "the key must not be written to the log")
        XCTAssertTrue(log.contains("env:  SPLASH_CRASH_TRACE=1 SPLASH_API_KEY=REDACTED"))
        XCTAssertTrue(log.contains("--host 0.0.0.0"))
    }
}
