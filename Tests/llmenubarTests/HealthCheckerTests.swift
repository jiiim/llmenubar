// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import XCTest

@testable import llmenubar

/// HealthChecker decides whether a confirmed-healthy server gets killed, so the
/// interesting behaviour is all in its guards: the consecutive-failure
/// threshold, the generation stamp that discards superseded responses, and the
/// switch to the steady cadence once a startup succeeds. These drive a real
/// loopback HTTP server rather than stubbing URLSession, because the guards are
/// about real response timing.
@MainActor
final class HealthCheckerTests: XCTestCase {

    /// Spin the main run loop until `condition` holds or `timeout` elapses. The
    /// checker schedules all of its work onto the main queue, so a blocking wait
    /// would deadlock it.
    /// The generous default is for the waits that expect an event: the poll
    /// timer carries up to a second of leeway, so three polls at a one-second
    /// cadence can take six. Waits that expect *no* event pass an explicit short
    /// timeout, since those run to completion every time.
    private func spin(
        timeout: TimeInterval = 15,
        until condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: - Readiness

    func testStopInsideReadinessCallbackDoesNotRecreatePolling() {
        let server = LoopbackStubServer()
        defer { server.stop() }
        let checker = HealthChecker(fastInterval: 1, steadyInterval: 30)
        defer { checker.stop() }
        var reported = false
        checker.isStartingUp = { true }
        checker.onHealthSuccess = {
            checker.stop()
            reported = true
        }
        checker.startPolling(readyURL: server.url, livenessURL: server.url)
        spin { reported }
        XCTAssertTrue(reported)
        XCTAssertFalse(checker.isPolling)
    }

    func testHealthyServerReportsSuccessOnceAndSlowsToSteadyCadence() {
        let server = LoopbackStubServer()
        defer { server.stop() }

        let checker = HealthChecker(fastInterval: 1, steadyInterval: 30)
        defer { checker.stop() }

        var successes = 0
        var startingUp = true
        checker.isStartingUp = { startingUp }
        checker.isRunning = { !startingUp }
        checker.onHealthSuccess = {
            successes += 1
            startingUp = false
        }
        checker.onUnreachable = { _ in XCTFail("a 200 response must not report unreachable") }

        checker.startPolling(readyURL: server.url, livenessURL: server.url)
        spin { successes > 0 }
        XCTAssertEqual(successes, 1)

        // The steady cadence is 30s, so no second success can land in the time
        // a handful of fast-cadence polls would have taken.
        spin(timeout: 1.5) { successes > 1 }
        XCTAssertEqual(successes, 1, "readiness should be reported once per start")
    }

    // MARK: - Failure threshold

    func testUnreachableIsReportedOnlyAfterTheFullRunOfFailures() {
        let server = LoopbackStubServer()
        server.statusCode = 500
        defer { server.stop() }

        let checker = HealthChecker(fastInterval: 1, failureThreshold: 3)
        defer { checker.stop() }

        var reports: [String] = []
        checker.isStartingUp = { false }
        checker.isRunning = { true }
        checker.onUnreachable = { reports.append($0) }

        checker.startPolling(readyURL: server.url, livenessURL: server.url)
        spin { !reports.isEmpty }

        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(
            reports[0].contains("unreachable for 3 checks"),
            "expected the threshold in the message, got: \(reports[0])"
        )
    }

    /// A child held still for a log rotation cannot answer. That is not an
    /// unresponsive server, however long the rotation takes.
    func testNoFailureIsCountedWhilePaused() {
        let server = LoopbackStubServer()
        server.statusCode = 500
        defer { server.stop() }

        let checker = HealthChecker(fastInterval: 1, failureThreshold: 2)
        defer { checker.stop() }

        var reports: [String] = []
        var paused = true
        checker.isStartingUp = { false }
        checker.isRunning = { true }
        checker.isPaused = { paused }
        checker.onUnreachable = { reports.append($0) }

        checker.startPolling(readyURL: server.url, livenessURL: server.url)
        let end = Date().addingTimeInterval(3.5)
        spin { Date() > end }
        XCTAssertEqual(reports, [], "no verdict while paused")
        XCTAssertEqual(checker.consecutiveFailures, 0)

        paused = false
        spin { !reports.isEmpty }
        XCTAssertEqual(reports.count, 1, "polling counts failures again once the child is released")
    }

    func testASuccessBetweenFailuresResetsTheRun() {
        let server = LoopbackStubServer()
        server.statusCode = 500
        defer { server.stop() }

        // A threshold of 3 with a success landing after the second failure: the
        // count must restart, so the two failures that follow cannot trip it.
        let checker = HealthChecker(fastInterval: 1, failureThreshold: 3)
        defer { checker.stop() }

        var failures = 0
        var reports = 0
        checker.isStartingUp = { false }
        checker.isRunning = { true }
        checker.onUnreachable = { _ in reports += 1 }

        // Count polls by watching the stub flip back and forth.
        checker.startPolling(readyURL: server.url, livenessURL: server.url)
        spin(timeout: 3) {
            failures = checker.consecutiveFailures
            return failures >= 2
        }
        XCTAssertEqual(reports, 0, "two failures must not reach a threshold of three")

        server.statusCode = 200
        spin(timeout: 3) { checker.consecutiveFailures == 0 }
        XCTAssertEqual(
            checker.consecutiveFailures, 0,
            "a success must clear the failure run"
        )
        XCTAssertEqual(reports, 0)
    }

    // MARK: - Generation guard

    func testResponsesLandingAfterStopAreDiscarded() {
        let server = LoopbackStubServer()
        server.statusCode = 500
        server.holdResponses()
        defer { server.stop() }

        let checker = HealthChecker(fastInterval: 1, failureThreshold: 1)
        defer { checker.stop() }

        var reports = 0
        checker.isStartingUp = { false }
        checker.isRunning = { true }
        checker.onUnreachable = { _ in reports += 1 }

        checker.startPolling(readyURL: server.url, livenessURL: server.url)
        // Wait for a request the server is holding unanswered. Stopping before
        // one is in flight would test the nil-URL guard in `issueHealthRequest`
        // instead: no request, so no response for the generation stamp to
        // discard.
        spin { server.requestsRead > 0 }
        XCTAssertGreaterThan(server.requestsRead, 0, "no request was ever issued")

        // Supersede the run, then let the 500 it is waiting on come back.
        checker.stop()
        server.releaseResponses()

        spin(timeout: 1.5) { reports > 0 }
        XCTAssertEqual(reports, 0, "a response from a stopped run must not act")
    }

    // MARK: - Stall advisory

    func testStallAdvisoryFiresOnceAndPollingContinues() {
        let server = LoopbackStubServer()
        server.statusCode = nil   // accept, never answer: a startup still loading
        defer { server.stop() }

        let checker = HealthChecker(fastInterval: 1, stallAdvisoryInterval: 0.1)
        defer { checker.stop() }

        var advisories = 0
        checker.isStartingUp = { true }
        checker.isRunning = { false }
        checker.onStartupStalled = { advisories += 1 }
        checker.onUnreachable = { _ in XCTFail("a starting server must not be reported unreachable") }

        checker.startPolling(readyURL: server.url, livenessURL: server.url)
        spin { advisories > 0 }
        XCTAssertEqual(advisories, 1)

        // Still polling, and still only the one advisory.
        spin(timeout: 2) { advisories > 1 }
        XCTAssertEqual(advisories, 1, "the advisory is once per start, not per poll")
    }

    // MARK: - Two endpoints

    private func url(_ server: LoopbackStubServer, _ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(server.port)\(path)")!
    }

    func testStartupWaitsOnReadyThenRunningIsWatchedThroughHealth() {
        let server = LoopbackStubServer()
        server.setStatus(503, forPath: "/ready")
        server.setStatus(200, forPath: "/health")
        defer { server.stop() }

        let checker = HealthChecker(fastInterval: 1, steadyInterval: 1)
        defer { checker.stop() }

        var successes = 0
        var startingUp = true
        checker.isStartingUp = { startingUp }
        checker.isRunning = { !startingUp }
        checker.onHealthSuccess = {
            successes += 1
            startingUp = false
        }
        checker.onUnreachable = { _ in XCTFail("a loading model is not an unreachable server") }

        checker.startPolling(
            readyURL: url(server, "/ready"),
            livenessURL: url(server, "/health")
        )

        // Not ready: polls reach /ready only, and report nothing.
        spin(timeout: 4) { server.requestPaths.count >= 2 }
        XCTAssertEqual(successes, 0)
        XCTAssertTrue(server.requestPaths.allSatisfy { $0 == "/ready" })

        server.setStatus(200, forPath: "/ready")
        spin { successes > 0 }
        XCTAssertEqual(successes, 1)

        // Running: the steady polls go to /health.
        let before = server.requestPaths.count
        spin { server.requestPaths.count > before }
        XCTAssertEqual(server.requestPaths.last, "/health")
    }

    func testRunningServerIgnoresReadyUnderMemoryPressure() {
        let server = LoopbackStubServer()
        server.setStatus(503, forPath: "/ready")
        server.setStatus(200, forPath: "/health")
        defer { server.stop() }

        let checker = HealthChecker(fastInterval: 1, steadyInterval: 1, failureThreshold: 2)
        defer { checker.stop() }

        var reports = 0
        checker.isStartingUp = { false }
        checker.isRunning = { true }
        checker.onUnreachable = { _ in reports += 1 }

        checker.startPolling(
            readyURL: url(server, "/ready"),
            livenessURL: url(server, "/health")
        )
        spin(timeout: 5) { server.requestPaths.count >= 4 }

        XCTAssertEqual(reports, 0, "/ready reports 503 under memory pressure; /health says alive")
        XCTAssertFalse(server.requestPaths.contains("/ready"))
    }
}
