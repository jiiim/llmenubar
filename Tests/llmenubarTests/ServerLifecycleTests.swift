// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest
@testable import llmenubar

final class ServerLifecycleTests: XCTestCase {
    private func running(_ model: inout ServerLifecycle, id: UUID) {
        _ = model.handle(.start(id, .manual))
        _ = model.handle(.launched(id, 42))
        _ = model.handle(.ready(id))
        XCTAssertEqual(model.status, .running(pid: 42))
    }

    func testStopSupersedesRestartAndHealthFailure() {
        for restart in [false, true] {
            var model = ServerLifecycle()
            let id = UUID()
            running(&model, id: id)
            _ = model.handle(restart ? .restart(UUID()) : .unhealthy(id, "unreachable"))
            _ = model.handle(.stop)
            let effects = model.handle(.exited(id, false, ""))
            XCTAssertEqual(model.status, .stopped)
            XCTAssertFalse(effects.contains { if case .waitForPort = $0 { return true }; return false })
        }
    }

    func testQuitCannotBeReplacedByOtherCommands() {
        var model = ServerLifecycle()
        let id = UUID()
        running(&model, id: id)
        _ = model.handle(.quit)
        _ = model.handle(.restart(UUID()))
        _ = model.handle(.start(UUID(), .manual))
        _ = model.handle(.stop)
        XCTAssertTrue(model.quitting)
        let effects = model.handle(.exited(id, true, ""))
        XCTAssertEqual(effects.filter { if case .completeQuit = $0 { return true }; return false }.count, 1)
        XCTAssertTrue(model.handle(.exited(id, true, "")).isEmpty)
        XCTAssertTrue(model.handle(.start(UUID(), .manual)).isEmpty)
    }

    func testReplacementRejectsEveryOldCompletion() {
        var model = ServerLifecycle()
        let old = UUID(), replacement = UUID()
        running(&model, id: old)
        _ = model.handle(.restart(UUID()))
        _ = model.handle(.exited(old, true, ""))
        _ = model.handle(.portAvailable(old, replacement))
        _ = model.handle(.launched(replacement, 99))
        _ = model.handle(.ready(replacement))
        for event: ServerLifecycle.Event in [
            .ready(old), .launched(old, 1), .launchFailed(old, "bad"),
            .unhealthy(old, "bad"), .exited(old, false, "bad"),
            .stable(old), .portAvailable(old, UUID())
        ] {
            XCTAssertTrue(model.handle(event).isEmpty)
            XCTAssertEqual(model.status, .running(pid: 99))
        }
    }

    func testAutomaticRestartBudgetAndNotificationTiming() {
        var model = ServerLifecycle()
        let first = UUID(), second = UUID()
        running(&model, id: first)
        let failure = model.handle(.exited(first, false, "failure"))
        XCTAssertTrue(model.restartAttempted)
        XCTAssertFalse(failure.contains { if case .notification = $0 { return true }; return false })
        _ = model.handle(.portAvailable(first, second))
        _ = model.handle(.launched(second, 43))
        let ready = model.handle(.ready(second))
        XCTAssertEqual(ready.filter { if case .notification = $0 { return true }; return false }.count, 1)
        XCTAssertTrue(model.handle(.ready(second)).isEmpty)
        _ = model.handle(.exited(second, false, "again"))
        guard case .error = model.status else { return XCTFail("restart budget should be exhausted") }
        _ = model.handle(.start(UUID(), .manual))
        XCTAssertFalse(model.restartAttempted)
    }

    func testStabilityOnlyResetsCurrentHealthyRun() {
        var model = ServerLifecycle()
        let first = UUID(), second = UUID()
        running(&model, id: first)
        _ = model.handle(.exited(first, false, ""))
        _ = model.handle(.portAvailable(first, second))
        _ = model.handle(.stable(first))
        _ = model.handle(.stable(second))
        XCTAssertTrue(model.restartAttempted)
        _ = model.handle(.launched(second, 43))
        _ = model.handle(.ready(second))
        _ = model.handle(.stable(second))
        XCTAssertFalse(model.restartAttempted)
    }

    func testCancelPortWaitAndLaunchFailureAreTerminal() {
        var model = ServerLifecycle()
        let first = UUID()
        running(&model, id: first)
        _ = model.handle(.restart(UUID()))
        _ = model.handle(.exited(first, true, ""))
        _ = model.handle(.stop)
        XCTAssertTrue(model.handle(.portAvailable(first, UUID())).isEmpty)
        let attempt = UUID()
        _ = model.handle(.start(attempt, .manual))
        XCTAssertEqual(model.handle(.launchFailed(attempt, "bad executable")).count, 2)
        XCTAssertTrue(model.handle(.launchFailed(attempt, "bad executable")).isEmpty)
        XCTAssertEqual(model.status, .error("bad executable"))
    }
}
