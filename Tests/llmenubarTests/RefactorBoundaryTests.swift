// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest
@testable import llmenubar

@MainActor
final class RefactorBoundaryTests: XCTestCase {
    private actor Samples {
        var pending: [String: CheckedContinuation<StartupPhase, Never>] = [:]
        func sample(_ name: String) async -> StartupPhase {
            await withCheckedContinuation { pending[name] = $0 }
        }
        func waiting(_ name: String) -> Bool { pending[name] != nil }
        func finish(_ name: String) {
            pending.removeValue(forKey: name)?.resume(returning: .downloading(.init(repository: name)))
        }
    }

    func testOldStartupSampleCannotUpdateNewRun() async {
        let samples = Samples()
        let monitor = StartupProgressMonitor(sampler: { config, _ in await samples.sample(config.huggingFaceModel) })
        var shown: StartupPhase = .starting
        monitor.onChange = { shown = $0 }
        var config = ServerConfiguration.Config()
        config.huggingFaceModel = "owner/old"
        monitor.start(configuration: config)
        for _ in 0..<1000 { if await samples.waiting("owner/old") { break }; await Task.yield() }
        config.huggingFaceModel = "owner/new"
        monitor.start(configuration: config)
        for _ in 0..<1000 { if await samples.waiting("owner/new") { break }; await Task.yield() }
        await samples.finish("owner/new")
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(shown.download?.repository, "owner/new")
        await samples.finish("owner/old")
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(shown.download?.repository, "owner/new")
        monitor.stop()
        XCTAssertEqual(shown, .starting)
    }

    func testWeightsDoNotSurviveRunReplacementWhenSpeedIsOff() {
        let presentation = ServerPresentation()
        var released = false
        presentation.onWeights = { released = $0 }
        presentation.status = .running(pid: 1)
        presentation.receiveWeights(.released)
        XCTAssertTrue(released)
        presentation.status = .stopping
        XCTAssertFalse(released)
        presentation.receiveWeights(.released)
        XCTAssertFalse(released)
        presentation.status = .running(pid: 2)
        XCTAssertFalse(released)
    }

    /// The rate belongs to the run that produced it: it goes when the run ends,
    /// and a restart's new run does not start with the old one's number.
    func testTheSpeedDoesNotOutliveItsRun() {
        let presentation = ServerPresentation()
        presentation.showsPerformanceInMenuBar = true
        var shown = ServerPerformance.idle
        presentation.onPerformance = { shown = $0 }
        let rate = ServerPerformance(phase: .generation, tokensPerSecond: 42)

        presentation.status = .running(pid: 1)
        presentation.receivePerformance(rate)
        XCTAssertEqual(shown, rate)

        presentation.status = .stopping
        XCTAssertEqual(shown, .idle, "stopping ends the run")
        presentation.receivePerformance(rate)
        XCTAssertEqual(shown, .idle, "a rate arriving after the run ended is not shown")

        presentation.status = .stopped
        presentation.status = .running(pid: 2)
        XCTAssertEqual(shown, .idle, "the next run starts with no rate")

        presentation.receivePerformance(rate)
        XCTAssertEqual(shown, rate)
        presentation.status = .restarting
        XCTAssertEqual(shown, .idle)
    }

    /// A publish or idle timer scheduled by the old run fires into the new one.
    func testScheduledDisplayWorkDoesNotPublishAfterTheRunEnds() {
        let presentation = ServerPresentation()
        presentation.showsPerformanceInMenuBar = true
        var shown: [ServerPerformance] = []
        presentation.onPerformance = { shown.append($0) }
        presentation.status = .running(pid: 1)
        // A burst: the second update is held behind the coalescing window.
        presentation.receivePerformance(ServerPerformance(phase: .generation, tokensPerSecond: 10))
        presentation.receivePerformance(ServerPerformance(phase: .generation, tokensPerSecond: 20))
        presentation.status = .stopped
        let count = shown.count
        let wait = expectation(description: "timers would have fired")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { wait.fulfill() }
        waitForExpectations(timeout: 3)
        XCTAssertEqual(shown.count, count, "no display work survives the run")
        XCTAssertEqual(shown.last, .idle)
    }

    func testOccupiedPortCannotBeMistakenForNewChildReadiness() throws {
        let stub = LoopbackStubServer()
        defer { stub.stop() }
        let manager = ProcessManager()
        var failure = ""
        manager.onLaunchFailure = { failure = $0 }
        var config = ServerConfiguration.Config()
        config.splashPath = "/bin/sleep"
        config.huggingFaceModel = "owner/model"
        config.host = "127.0.0.1"
        config.port = Int(stub.port)
        XCTAssertNil(manager.launch(configuration: config))
        XCTAssertTrue(failure.contains("already in use"), failure)
        XCTAssertFalse(manager.hasPendingRun)
    }

    func testInspectionTimeoutKillsAnUnresponsiveChild() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let script = directory.appendingPathComponent("inspect")
        try Data("#!/bin/sh\ntrap '' TERM\necho $$ > '\(pidFile.path)'\nexec /bin/sleep 60\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        XCTAssertNil(SplashBuild.run(script.path, [], timeout: 0.3))
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}
