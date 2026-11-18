// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest

@testable import llmenubar

/// What `ProcessManager.launch` checks, builds and records before and as it
/// starts `splash serve`. The child is a script, so nothing here loads a model.
@MainActor
final class ProcessLaunchTests: XCTestCase {
    private func makeDirectory(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeScript(in directory: URL, _ body: String) throws -> URL {
        let url = directory.appendingPathComponent("splash")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func configuration(splash: URL, in directory: URL) -> ServerConfiguration.Config {
        var config = ServerConfiguration.Config()
        config.splashPath = splash.path
        config.huggingFaceModel = "owner/repo:Q4"
        config.logPath = directory.appendingPathComponent("server.log").path
        return config
    }

    private func spin(timeout: TimeInterval = 5, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: Arguments and environment

    func testTheChildReceivesTheServeCommandAndTheLogRecordsIt() throws {
        let directory = try makeDirectory("argv")
        let argsFile = directory.appendingPathComponent("args")
        let environmentFile = directory.appendingPathComponent("env")
        let splash = try makeScript(in: directory, """
        for a in "$@"; do printf '%s\\n' "$a"; done > '\(argsFile.path)'
        pwd > '\(argsFile.path).cwd'
        env > '\(environmentFile.path).partial' && mv '\(environmentFile.path).partial' '\(environmentFile.path)'
        exec /bin/sleep 5
        """)
        var config = configuration(splash: splash, in: directory)
        config.port = 8_123
        config.maxContext = "128K"

        let manager = ProcessManager()
        defer { if manager.isProcessRunning { manager.terminate() } }
        setenv("LLMENUBAR_TEST_MARKER", "inherited", 1)
        defer { unsetenv("LLMENUBAR_TEST_MARKER") }

        XCTAssertNotNil(manager.launch(configuration: config))
        spin { FileManager.default.fileExists(atPath: environmentFile.path) }

        let received = try String(contentsOf: argsFile, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(received, SplashCommand.arguments(configuration: config))
        XCTAssertEqual(received.first, "serve")

        let cwd = try String(contentsOfFile: argsFile.path + ".cwd", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path,
            FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        )
        let environment = try String(contentsOf: environmentFile, encoding: .utf8)
        XCTAssertTrue(environment.contains("LLMENUBAR_TEST_MARKER=inherited"))

        let log = try String(contentsOfFile: config.logPath, encoding: .utf8)
        XCTAssertTrue(log.contains("=== llmenubar launch"))
        XCTAssertTrue(log.contains("exec: \(splash.path)"))
        XCTAssertTrue(log.contains("argv: " + SplashCommand.arguments(configuration: config).joined(separator: " ")))
    }

    /// A token for a gated model is as private as the API key, and a reporter is
    /// asked to paste the log's `env:` line.
    func testOtherSecretsStayOutOfTheLogToo() throws {
        let directory = try makeDirectory("secrets")
        let splash = try makeScript(in: directory, "exec /bin/sleep 5")
        var config = configuration(splash: splash, in: directory)
        config.environment = "HF_TOKEN=hf_abc123\nHUGGING_FACE_HUB_TOKEN=hf_def456\nMY_Password=pw1\nSPLASH_CRASH_TRACE=1"

        let manager = ProcessManager()
        defer { if manager.isProcessRunning { manager.terminate() } }
        XCTAssertNotNil(manager.launch(configuration: config))

        let log = try String(contentsOfFile: config.logPath, encoding: .utf8)
        for secret in ["hf_abc123", "hf_def456", "pw1"] {
            XCTAssertFalse(log.contains(secret), secret)
        }
        XCTAssertTrue(log.contains("HF_TOKEN=REDACTED"), log)
        XCTAssertTrue(log.contains("SPLASH_CRASH_TRACE=1"), log)
    }

    func testTheKeyReachesTheChildThroughTheEnvironmentAndStaysOutOfTheLog() throws {
        let directory = try makeDirectory("key")
        let environmentFile = directory.appendingPathComponent("env")
        let argsFile = directory.appendingPathComponent("args")
        let splash = try makeScript(in: directory, """
        echo "$@" > '\(argsFile.path)'
        env > '\(environmentFile.path).partial' && mv '\(environmentFile.path).partial' '\(environmentFile.path)'
        exec /bin/sleep 5
        """)
        var config = configuration(splash: splash, in: directory)
        config.apiKey = "llm-very-secret-key"
        config.environment = "SPLASH_CRASH_TRACE=1"

        let manager = ProcessManager()
        defer { if manager.isProcessRunning { manager.terminate() } }
        XCTAssertNotNil(manager.launch(configuration: config))
        spin { FileManager.default.fileExists(atPath: environmentFile.path) }

        let environment = try String(contentsOf: environmentFile, encoding: .utf8)
        XCTAssertTrue(environment.contains("SPLASH_API_KEY=llm-very-secret-key"))
        XCTAssertTrue(environment.contains("SPLASH_CRASH_TRACE=1"))
        XCTAssertFalse(try String(contentsOf: argsFile, encoding: .utf8).contains("llm-very-secret-key"))

        let log = try String(contentsOfFile: config.logPath, encoding: .utf8)
        XCTAssertFalse(log.contains("llm-very-secret-key"), "the key must not be written to the log")
        XCTAssertTrue(log.contains("env:  SPLASH_CRASH_TRACE=1 SPLASH_API_KEY=REDACTED"), log)
    }

    // MARK: Health endpoints

    /// A listener that accepts every interface is reached from this Mac through
    /// loopback, whichever way its address is written.
    func testHealthEndpointsForAnUnspecifiedHostPointAtLoopback() throws {
        let directory = try makeDirectory("endpoints")
        let splash = try makeScript(in: directory, "exec /bin/sleep 5")
        let cases: [(host: String, base: String)] = [
            ("0.0.0.0", "http://127.0.0.1:8123"),
            // IPv6 hosts are refused while Splash listens on IPv4 only
            // (`ListenAddress.acceptsIPv6`); the URL side is covered in
            // ListenAddressTests.
            ("127.0.0.1", "http://127.0.0.1:8123"),
            ("localhost", "http://localhost:8123"),
        ]
        for (host, base) in cases {
            var config = configuration(splash: splash, in: directory)
            config.host = host
            config.port = 8_123
            let manager = ProcessManager()
            defer { if manager.isProcessRunning { manager.terminate() } }

            let endpoints = manager.launch(configuration: config)
            XCTAssertEqual(endpoints?.ready?.absoluteString, base + "/ready", host)
            XCTAssertEqual(endpoints?.liveness?.absoluteString, base + "/health", host)
            XCTAssertTrue(manager.isProcessRunning, "the child must really be running for \(host)")
        }
    }

    /// A socket has no URL: the health checker is given its path instead, and
    /// the child is given the expanded path to bind.
    func testASocketHostGivesTheHealthCheckerThePathNotAURL() throws {
        let directory = try makeDirectory("socket")
        let argsFile = directory.appendingPathComponent("args")
        let splash = try makeScript(in: directory, """
        echo "$@" > '\(argsFile.path)'
        exec /bin/sleep 5
        """)
        var config = configuration(splash: splash, in: directory)
        let socket = "/tmp/llmb-\(UUID().uuidString.prefix(8)).sock"
        config.host = "unix:" + socket
        let manager = ProcessManager()
        defer { if manager.isProcessRunning { manager.terminate() } }

        let endpoints = manager.launch(configuration: config)
        XCTAssertEqual(endpoints, .unixSocket(path: socket))
        XCTAssertNil(endpoints?.ready)
        XCTAssertTrue(manager.isProcessRunning)
        spin { FileManager.default.fileExists(atPath: argsFile.path) }
        let received = try String(contentsOf: argsFile, encoding: .utf8)
        XCTAssertTrue(received.contains("--host unix:" + socket), received)
    }

    func testALaunchIsRefusedWhileAServerHoldsTheSocket() throws {
        let directory = try makeDirectory("socketbusy")
        let marker = directory.appendingPathComponent("ran")
        let splash = try makeScript(in: directory, "touch '\(marker.path)'; exec /bin/sleep 5")
        let server = UnixStubServer()
        defer { server.stop() }
        var config = configuration(splash: splash, in: directory)
        config.host = "unix:" + server.path
        let manager = ProcessManager()
        var failure: String?
        manager.onLaunchFailure = { failure = $0 }

        XCTAssertNil(manager.launch(configuration: config))
        XCTAssertTrue(failure?.contains("already holds") == true, failure ?? "no message")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the engine must not start")
        XCTAssertFalse(manager.isProcessRunning)
    }

    func testAHostThatMakesNoURLFailsBeforeAnythingRuns() throws {
        let directory = try makeDirectory("badhost")
        let marker = directory.appendingPathComponent("ran")
        let splash = try makeScript(in: directory, "touch '\(marker.path)'")
        var config = configuration(splash: splash, in: directory)
        config.host = "bad host"

        let manager = ProcessManager()
        var failure: String?
        manager.onLaunchFailure = { failure = $0 }
        XCTAssertNil(manager.launch(configuration: config))
        XCTAssertNotNil(failure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "an invalid launch must not run splash")
    }

    // MARK: Pre-flight

    func testLaunchRefusesAnInvalidConfigurationAndSaysWhy() throws {
        let directory = try makeDirectory("invalid")
        let splash = try makeScript(in: directory, "exec /bin/sleep 5")
        var config = configuration(splash: splash, in: directory)
        config.maxContext = "lots"

        let manager = ProcessManager()
        var failure: String?
        manager.onLaunchFailure = { failure = $0 }
        XCTAssertNil(manager.launch(configuration: config))
        XCTAssertTrue(failure?.hasPrefix("Invalid server configuration: ") == true, failure ?? "nil")
        XCTAssertFalse(manager.isProcessRunning)
    }

    func testLaunchRefusesLocalFilesThatAreNotAModel() throws {
        let directory = try makeDirectory("badmodel")
        let splash = try makeScript(in: directory, "exec /bin/sleep 5")
        let notGGUF = directory.appendingPathComponent("m.gguf")
        try Data("not a model".utf8).write(to: notGGUF)
        var config = configuration(splash: splash, in: directory)
        config.modelSource = .local
        config.modelPath = notGGUF.path

        let manager = ProcessManager()
        var failure: String?
        manager.onLaunchFailure = { failure = $0 }
        XCTAssertNil(manager.launch(configuration: config))
        XCTAssertEqual(failure, "model is neither a GGUF file nor a folder at \(notGGUF.path)")

        config.modelPath = directory.appendingPathComponent("missing.gguf").path
        XCTAssertNil(manager.launch(configuration: config))
        XCTAssertEqual(failure, "model not found at \(config.modelPath)")
    }

    func testLaunchChecksTheProjectorOnlyWhereItIsUsed() throws {
        let directory = try makeDirectory("projector")
        let splash = try makeScript(in: directory, "exec /bin/sleep 5")
        let model = directory.appendingPathComponent("m.gguf")
        try Data("GGUF....".utf8).write(to: model)
        var config = configuration(splash: splash, in: directory)
        config.modelSource = .local
        config.modelPath = model.path
        config.visionProjectorPath = directory.appendingPathComponent("mmproj.gguf").path

        let manager = ProcessManager()
        defer { if manager.isProcessRunning { manager.terminate() } }
        var failure: String?
        manager.onLaunchFailure = { failure = $0 }
        XCTAssertNil(manager.launch(configuration: config))
        XCTAssertEqual(failure, "vision projector not readable at \(config.visionProjectorPath)")

        config.languageOnly = true
        XCTAssertNotNil(manager.launch(configuration: config), "a text-only launch never reads the projector")
    }

    func testLaunchCreatesTheChosenCacheFolderOwnerOnly() throws {
        let directory = try makeDirectory("cache")
        let splash = try makeScript(in: directory, "exec /bin/sleep 5")
        let cache = directory.appendingPathComponent("prefix-cache")
        var config = configuration(splash: splash, in: directory)
        config.persistentCache = true
        config.cacheDirectory = cache.path

        let manager = ProcessManager()
        defer { if manager.isProcessRunning { manager.terminate() } }
        XCTAssertNotNil(manager.launch(configuration: config))

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as? NSNumber)?.int16Value,
            0o700
        )
    }

    func testNoCacheFolderIsCreatedUnlessTheCacheIsKept() throws {
        let directory = try makeDirectory("nocache")
        let splash = try makeScript(in: directory, "exec /bin/sleep 5")
        let cache = directory.appendingPathComponent("prefix-cache")
        var config = configuration(splash: splash, in: directory)
        config.cacheDirectory = cache.path

        let manager = ProcessManager()
        defer { if manager.isProcessRunning { manager.terminate() } }
        XCTAssertNotNil(manager.launch(configuration: config))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }

    // MARK: Failure reasons

    func testFailureReasonPrefersTheComplaintThatFollowsTheUsage() throws {
        let directory = try makeDirectory("reason")
        let log = """
        === llmenubar launch 2026-11-10 09:00:00 ===
        exec: /opt/homebrew/bin/splash
        cwd:  /Users/me
        argv: serve --model owner/repo --port 99999
        ---
        usage: splash serve [-h] --model OWNER/REPO[:VARIANT] [--model-dir PATH]
                            [--port PORT] [--host ADDRESS]
        splash serve: error: argument --port: port must be between 1 and 65535
        """
        let logURL = directory.appendingPathComponent("server.log")
        try Data(log.utf8).write(to: logURL)

        XCTAssertEqual(
            ProcessManager().launchFailureReason(logPath: logURL.path),
            "splash serve: error: argument --port: port must be between 1 and 65535"
        )
    }

    func testFailureReasonIgnoresEarlierLaunchesAndFallsBackToTheLastLine() throws {
        let directory = try makeDirectory("reason2")
        let log = """
        === llmenubar launch 2026-11-10 08:00:00 ===
        argv: serve
        ---
        splash serve: error: an old problem
        === llmenubar launch 2026-11-10 09:00:00 ===
        argv: serve
        ---
        11:00:01 Loading · owner/repo
        11:00:09 Stopping · releasing engine resources
        """
        let logURL = directory.appendingPathComponent("server.log")
        try Data(log.utf8).write(to: logURL)

        let manager = ProcessManager()
        XCTAssertEqual(
            manager.launchFailureReason(logPath: logURL.path),
            "11:00:09 Stopping · releasing engine resources"
        )
        XCTAssertEqual(
            manager.lastLogReason(logPath: logURL.path),
            "11:00:09 Stopping · releasing engine resources"
        )
    }

    func testAPythonFailureReportsItsException() throws {
        let directory = try makeDirectory("traceback")
        let log = """
        === llmenubar launch 2026-11-10 09:00:00 ===
        argv: serve
        ---
        Traceback (most recent call last):
          File "install/launcher.py", line 12, in main
        ModelError: unsupported GGUF model architecture: foo
        """
        let logURL = directory.appendingPathComponent("server.log")
        try Data(log.utf8).write(to: logURL)
        XCTAssertEqual(
            ProcessManager().launchFailureReason(logPath: logURL.path),
            "ModelError: unsupported GGUF model architecture: foo"
        )
    }
}
