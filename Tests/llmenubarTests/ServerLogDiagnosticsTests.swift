// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest

@testable import llmenubar

final class ServerLogDiagnosticsTests: XCTestCase {
    private func log(_ text: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-diagnostics-\(UUID().uuidString).log")
        try Data(text.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    /// A download redraws one line with carriage returns. The last redraw is the
    /// reason, not the whole transfer.
    func testCarriageReturnProgressIsSplitIntoLines() throws {
        let progress = (1...400).map { "Downloading model.gguf  \($0)%" }.joined(separator: "\r")
        let path = try log("=== llmenubar launch x ===\nstarting\n" + progress + "\nSegmentation fault")
        XCTAssertEqual(ServerLogDiagnostics.lastLogReason(logPath: path), "Segmentation fault")

        let onlyProgress = try log(progress)
        XCTAssertEqual(ServerLogDiagnostics.lastLogReason(logPath: onlyProgress), "Downloading model.gguf  400%")
    }

    func testALongLineIsBoundedWithAnEllipsis() throws {
        let path = try log("error: " + String(repeating: "x", count: 50_000))
        let reason = ServerLogDiagnostics.lastLogReason(logPath: path)
        XCTAssertEqual(reason.count, ServerLogDiagnostics.maximumLineLength)
        XCTAssertTrue(reason.hasPrefix("error: xxx"))
        XCTAssertTrue(reason.hasSuffix("…"))
        XCTAssertEqual(ServerLogDiagnostics.launchFailureReason(logPath: path), reason)
    }

    func testOrdinaryLinesAreUnchanged() throws {
        let path = try log("usage: splash serve\nerror: unrecognized arguments: --nope\n")
        XCTAssertEqual(ServerLogDiagnostics.launchFailureReason(logPath: path),
                       "error: unrecognized arguments: --nope")
    }
}
