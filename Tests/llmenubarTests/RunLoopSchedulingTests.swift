// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest

@testable import llmenubar

final class RunLoopSchedulingTests: XCTestCase {
    /// What a quit needs: while work started here waits in a nested run loop,
    /// blocks of the main dispatch queue still run.
    @MainActor
    func testANestedLoopServesTheMainQueue() {
        let finished = expectation(description: "the nested loop saw the queue block")
        RunLoopScheduling.perform {
            var queueBlockRan = false
            DispatchQueue.main.async { queueBlockRan = true }
            let end = Date().addingTimeInterval(2)
            while !queueBlockRan, Date() < end {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            XCTAssertTrue(queueBlockRan)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
    }
}
