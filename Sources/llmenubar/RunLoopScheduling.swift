// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation

/// Where to start work that waits in a nested run loop.
///
/// A nested run loop, such as an alert's modal session or `NSApp.terminate`
/// waiting for its reply, cannot run other blocks of the main dispatch queue
/// while it sits inside one: the queue is serial, and the block that started
/// the loop has not returned. Work that must finish before the loop ends
/// (stopping the engine, seeing it exit) is made of such blocks, so a quit
/// begun from a main-queue block waits for ever. A block performed on the run
/// loop is a source of the loop and not a block of the queue, so the nested
/// loop serves the queue as usual.
enum RunLoopScheduling {
    /// Runs `work` on the main run loop, in every common mode, after the
    /// current call returns.
    static func perform(_ work: @escaping @MainActor () -> Void) {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { work() }
        }
    }
}
