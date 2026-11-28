// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import AppKit
import CoreText
import Foundation
import XCTest

@testable import llmenubar

final class ServerPerformanceTests: XCTestCase {
    func testParsesRequestStartsEndsAndPartialLines() {
        var parser = ServerPerformanceLogParser()

        XCTAssertEqual(
            parser.ingest(Data(
                "19:17:29 Started · input 131 · cached 0 · effort absent · thinking on\n".utf8
            )),
            []
        )
        XCTAssertTrue(
            parser.sawRequestActivity,
            "a request start is activity even though it carries no rate"
        )

        let firstHalf = "19:17:40 Done · input 131 · cached 0 · output 759 · TTFT 1.0s · 74."
        XCTAssertTrue(parser.ingest(Data(firstHalf.utf8)).isEmpty)
        XCTAssertEqual(
            parser.ingest(Data("2 tok/s · 3.9 tok/cycle\n".utf8)),
            [ServerPerformance(phase: .generation, tokensPerSecond: 74.2)]
        )
        XCTAssertTrue(parser.sawRequestActivity, "a finished request is request work")

        XCTAssertEqual(
            parser.ingest(Data("19:18:02 Cancelled · input 90 · cached 0 · output 4\n".utf8)),
            [],
            "the last rate stays"
        )
        XCTAssertTrue(parser.sawRequestActivity)

        XCTAssertEqual(
            parser.ingest(Data("19:20:13 Stopping · releasing engine resources\n".utf8)),
            [.idle]
        )
        XCTAssertFalse(parser.sawRequestActivity, "a shutdown is not activity")
    }

    func testWeightsReleasedAndRestoredAreReported() {
        var parser = ServerPerformanceLogParser()
        let release = """
        03:56:13 Neural Engine FFN program unloaded while idle
        03:56:13 Weights released after 600 s without a request; the next request restores them

        """
        XCTAssertEqual(parser.ingest(Data(release.utf8)), [])
        XCTAssertEqual(parser.weightsEvent, .released)
        XCTAssertFalse(parser.sawRequestActivity, "giving the weights back is not a request")

        _ = parser.ingest(Data("04:10:00 Weights released on request; the next request restores them\n".utf8))
        XCTAssertEqual(parser.weightsEvent, .released)

        _ = parser.ingest(Data("04:12:00 Weights restored in 1.84 s\n".utf8))
        XCTAssertEqual(parser.weightsEvent, .restored)

        _ = parser.ingest(Data("04:12:01 Weights not restored: no request waits for them\n".utf8))
        XCTAssertEqual(parser.weightsEvent, .released)

        _ = parser.ingest(Data("04:12:02 Weights wait for memory to be restored: 4 GiB free\n".utf8))
        XCTAssertNil(parser.weightsEvent, "waiting is neither")
    }

    func testTheLastWeightsEventInOneReadWins() {
        var parser = ServerPerformanceLogParser()
        let lines = """
        03:56:13 Weights released after 600 s without a request; the next request restores them
        03:58:02 Weights restored in 1.84 s

        """
        _ = parser.ingest(Data(lines.utf8))
        XCTAssertEqual(parser.weightsEvent, .restored)
    }

    func testAPrefillRateComesWithTheFirstTokenOfItsRequest() {
        var parser = ServerPerformanceLogParser()
        _ = parser.ingest(Data("""
        19:37:10 Started · request 202 · input 3,315 · cached 224 · effort absent · thinking on
        19:37:10 Started · request 203 · input 1,200 · cached 200 · effort absent · thinking on

        """.utf8))
        XCTAssertTrue(parser.rates.isEmpty)

        _ = parser.ingest(Data("19:37:13 TTFT of request 202: 3545.02 ms: own prefill 3544, claim wait 0, decode 0, other prefill 0, unit wait 0, rest 1.01742\n".utf8))
        XCTAssertEqual(parser.rates.prefill ?? 0, 3_091 / 3.544, accuracy: 0.001)
        XCTAssertNil(parser.rates.generation)
        XCTAssertTrue(parser.sawRequestActivity)

        // The other request is matched by its number, whenever its line comes.
        _ = parser.ingest(Data("19:37:14 TTFT of request 203: 9000 ms: own prefill 500, claim wait 0, rest 8500\n".utf8))
        XCTAssertEqual(parser.rates.prefill, 2_000)

        _ = parser.ingest(Data("19:37:33 Done · request 202 · input 3,315 · cached 224 · output 2,088 · TTFT 3.5s · 104.5 tok/s\n".utf8))
        XCTAssertEqual(parser.rates, ServerRates(generation: 104.5))
    }

    func testBothRatesOfOneReadAreKept() {
        var parser = ServerPerformanceLogParser()
        _ = parser.ingest(Data("""
        19:36:25 Started · request 1 · input 259 · cached 59
        19:36:25 TTFT of request 1: 440 ms: own prefill 400, claim wait 0
        19:36:52 Done · request 1 · input 259 · cached 59 · output 3 · 114.3 tok/s

        """.utf8))
        XCTAssertEqual(parser.rates, ServerRates(prefill: 500, generation: 114.3))
    }

    func testNoPrefillRateWithoutAMatchingStartOrTokensOrTime() {
        let cases = [
            // No start line.
            "19:00:01 TTFT of request 5: 10 ms: own prefill 10, claim wait 0",
            // Nothing to prefill.
            "19:00:00 Started · request 5 · input 100 · cached 100\n19:00:01 TTFT of request 5: 10 ms: own prefill 10, claim wait 0",
            // No time.
            "19:00:00 Started · request 5 · input 100 · cached 0\n19:00:01 TTFT of request 5: 10 ms: own prefill 0, claim wait 0",
            // Ended before its line.
            "19:00:00 Started · request 5 · input 100 · cached 0\n19:00:01 Cancelled · request 5 · input 100\n19:00:02 TTFT of request 5: 10 ms: own prefill 10, claim wait 0",
            "19:00:00 Started · request 5 · input 100 · cached 0\n19:00:01 Error · request 5 · capacity_exhausted\n19:00:02 TTFT of request 5: 10 ms: own prefill 10, claim wait 0",
            // Another run's request of the same number.
            "19:00:00 Started · request 5 · input 100 · cached 0\n19:00:01 Stopping · releasing engine resources\n19:00:02 TTFT of request 5: 10 ms: own prefill 10, claim wait 0",
            // A line cut short.
            "19:00:00 Started · request 5 · input 100 · cached 0\n19:00:01 TTFT of request 5",
        ]
        for lines in cases {
            var parser = ServerPerformanceLogParser()
            _ = parser.ingest(Data((lines + "\n").utf8))
            XCTAssertNil(parser.rates.prefill, lines)
        }
    }

    func testTheMenuNamesTheRatesItHas() {
        XCTAssertNil(ServerRates().menuDescription)
        XCTAssertEqual(ServerRates(prefill: 739.4).menuDescription, "Prefill 739 t/s")
        XCTAssertEqual(ServerRates(generation: 74.24).menuDescription, "Generation 74.2 t/s")
        XCTAssertEqual(
            ServerRates(prefill: 1_332, generation: 99.96).menuDescription,
            "Prefill 1,332 t/s · Generation 100 t/s"
        )
    }

    func testARateThatIsNoSpeedIsNeitherShownNorKept() {
        for rate in [-1, .nan, .infinity, 1e19] as [Double] {
            XCTAssertNil(ServerRates(prefill: rate, generation: rate).menuDescription, "\(rate)")
            var kept = ServerRates(prefill: 739, generation: 74)
            kept.merge(ServerRates(prefill: rate, generation: rate))
            XCTAssertEqual(kept, ServerRates(prefill: 739, generation: 74), "\(rate)")
        }

        var parser = ServerPerformanceLogParser()
        _ = parser.ingest(Data("""
        19:00:00 Started · request 5 · input 100 · cached 0
        19:00:01 TTFT of request 5: 10 ms: own prefill 1e-308, claim wait 0

        """.utf8))
        XCTAssertNil(parser.rates.prefill)
    }

    func testAFinishedRequestWithoutARateLeavesTheLastOne() {
        var parser = ServerPerformanceLogParser()
        XCTAssertEqual(
            parser.ingest(Data("19:17:40 Done · input 5 · cached 0 · output 0\n".utf8)),
            []
        )
        XCTAssertTrue(parser.sawRequestActivity)
    }

    func testIgnoresUnrelatedAndMisleadingLines() {
        var parser = ServerPerformanceLogParser()
        let lines = """
        19:10:44 Loading · unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M
        19:10:50 Ready · unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M · context 139,257 · http://127.0.0.1:8000
        19:17:56 Error · not_found · GET /apple-touch-icon.png
        19:19:58 Error · model_not_found · POST /v1/chat/completions
        Done · input 1 · output 1 · 9.0 tok/s
        1917:40 Done · input 1 · output 1 · 9.0 tok/s
        The Started · line of a story
        """
        XCTAssertTrue(parser.ingest(Data((lines + "\n").utf8)).isEmpty)
        XCTAssertFalse(parser.sawRequestActivity, "no line here is a request record")
    }

    func testMenuBarTextIsFixedWidth() {
        let values = [
            ServerPerformance.idle,
            ServerPerformance(phase: .prefill, tokensPerSecond: nil),
            ServerPerformance(phase: .generation, tokensPerSecond: .nan),
            ServerPerformance(phase: .prefill, tokensPerSecond: 8.4),
            ServerPerformance(phase: .generation, tokensPerSecond: 36.7),
            ServerPerformance(phase: .prefill, tokensPerSecond: 629),
            ServerPerformance(phase: .prefill, tokensPerSecond: 1_234),
            ServerPerformance(phase: .prefill, tokensPerSecond: 12_345),
        ]

        XCTAssertEqual(values.map(\.menuBarText), [
            "---- t/s",
            "---- t/s",
            "---- t/s",
            " 8.4 t/s",
            "36.7 t/s",
            " 629 t/s",
            "1.2k t/s",
            " 12k t/s",
        ])
        XCTAssertTrue(values.allSatisfy { $0.menuBarText.count == 8 })
        XCTAssertFalse(values.contains { $0.menuBarText.hasPrefix("G") || $0.menuBarText.hasPrefix("P") },
                       "no phase letter is drawn")
    }

    @MainActor
    func testRenderedMenuBarFieldsKeepEveryGlyphPosition() {
        let values = [
            ServerPerformance.idle,
            ServerPerformance(phase: .prefill, tokensPerSecond: 8.4),
            ServerPerformance(phase: .generation, tokensPerSecond: 36.7),
            ServerPerformance(phase: .prefill, tokensPerSecond: 629),
            ServerPerformance(phase: .prefill, tokensPerSecond: 1_234),
            ServerPerformance(phase: .prefill, tokensPerSecond: 12_345),
        ]
        let positions = values.map {
            glyphPositions(in: StatusItemRenderer.rateText($0.menuBarRate))
        }

        XCTAssertTrue(positions.allSatisfy { $0.count == positions[0].count })
        for candidate in positions.dropFirst() {
            XCTAssertEqual(candidate, positions[0])
        }
    }

    private func glyphPositions(in title: NSAttributedString) -> [CGFloat] {
        let line = CTLineCreateWithAttributedString(title)
        return (0..<title.length).map {
            CGFloat(CTLineGetOffsetForStringIndex(line, $0, nil))
        } + [CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))]
    }

    // MARK: - Display policy

    /// The rate field holds four columns, so Splash's extra precision is
    /// discarded before anything is drawn. Two records that reduce to the same
    /// characters are the same value as far as the user is concerned.
    func testDisplayIdentityIgnoresPrecisionTheFieldsCannotShow() {
        let coarse = ServerPerformance(phase: .generation, tokensPerSecond: 12.31)
        let finer = ServerPerformance(phase: .generation, tokensPerSecond: 12.34)
        XCTAssertNotEqual(coarse, finer)
        XCTAssertEqual(coarse.displayIdentity, finer.displayIdentity)

        let fast = ServerPerformance(phase: .prefill, tokensPerSecond: 388.30)
        let faster = ServerPerformance(phase: .prefill, tokensPerSecond: 388.40)
        XCTAssertEqual(fast.displayIdentity, faster.displayIdentity)

        let changed = ServerPerformance(phase: .generation, tokensPerSecond: 13.31)
        XCTAssertNotEqual(coarse.displayIdentity, changed.displayIdentity)
        // The phase is not drawn, so the same rate in another phase looks the same.
        XCTAssertEqual(
            coarse.displayIdentity,
            ServerPerformance(phase: .prefill, tokensPerSecond: 12.31).displayIdentity
        )
    }

    /// A converged average produces a record every few dozen milliseconds that
    /// renders to the same four characters. Publishing those redrew the status
    /// item twice a second to no visible effect.
    func testPolicySuppressesAPublishThatChangesNothingOnScreen() {
        var policy = PerformanceDisplayPolicy()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let shown = ServerPerformance(phase: .generation, tokensPerSecond: 30.0)
        let indistinguishable = ServerPerformance(phase: .generation, tokensPerSecond: 30.04)
        let different = ServerPerformance(phase: .generation, tokensPerSecond: 31.0)

        XCTAssertEqual(policy.receive(shown, now: start), [.display(shown)])
        // The coalescing window has elapsed, so this takes the publish path
        // and is dropped there rather than being queued.
        XCTAssertEqual(policy.receive(indistinguishable, now: start.addingTimeInterval(0.5)), [])
        XCTAssertEqual(policy.displayed, indistinguishable)

        // The suppressed publish still consumed the window, so a value that
        // does change the display is coalesced against it.
        XCTAssertEqual(
            policy.receive(different, now: start.addingTimeInterval(0.75)),
            [.schedulePublish(after: 0.25)]
        )
        XCTAssertEqual(
            policy.publishTimerFired(now: start.addingTimeInterval(1)),
            [.display(different)]
        )
    }

    func testPolicyPublishesAPhaseChangeWithoutWaitingOutTheWindow() {
        var policy = PerformanceDisplayPolicy()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let prefill = ServerPerformance(phase: .prefill, tokensPerSecond: 400)
        let generation = ServerPerformance(phase: .generation, tokensPerSecond: 30)

        XCTAssertEqual(policy.receive(prefill, now: start), [.display(prefill)])
        // Well inside the 0.5s coalescing window opened by the publish above.
        XCTAssertEqual(
            policy.receive(generation, now: start.addingTimeInterval(0.1)),
            [.display(generation)]
        )
        XCTAssertEqual(policy.displayed, generation)
    }

    func testPolicyCoalescesSamePhaseRatesAndPublishesTheNewest() {
        var policy = PerformanceDisplayPolicy()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let first = ServerPerformance(phase: .generation, tokensPerSecond: 30)
        let second = ServerPerformance(phase: .generation, tokensPerSecond: 31)
        let third = ServerPerformance(phase: .generation, tokensPerSecond: 32)

        XCTAssertEqual(policy.receive(first, now: start), [.display(first)])
        XCTAssertEqual(
            policy.receive(second, now: start.addingTimeInterval(0.1)),
            [.schedulePublish(after: 0.4)]
        )
        // Already scheduled: a further update replaces the queued value
        // without arming a second timer.
        XCTAssertEqual(policy.receive(third, now: start.addingTimeInterval(0.2)), [])
        XCTAssertEqual(policy.displayed, first)

        XCTAssertEqual(
            policy.publishTimerFired(now: start.addingTimeInterval(0.5)),
            [.display(third)]
        )
        XCTAssertEqual(policy.displayed, third)
    }

    /// A timer that has come due but not yet run must not publish its stale
    /// value over an update that arrived in the meantime.
    func testPolicyDiscardsAQueuedValueSupersededByADirectPublish() {
        var policy = PerformanceDisplayPolicy()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let first = ServerPerformance(phase: .generation, tokensPerSecond: 30)
        let queued = ServerPerformance(phase: .generation, tokensPerSecond: 31)
        let latest = ServerPerformance(phase: .generation, tokensPerSecond: 32)

        XCTAssertEqual(policy.receive(first, now: start), [.display(first)])
        XCTAssertEqual(
            policy.receive(queued, now: start.addingTimeInterval(0.1)),
            [.schedulePublish(after: 0.4)]
        )
        XCTAssertEqual(
            policy.receive(latest, now: start.addingTimeInterval(0.6)),
            [.cancelPublish, .display(latest)]
        )
        XCTAssertEqual(policy.publishTimerFired(now: start.addingTimeInterval(0.6)), [])
        XCTAssertEqual(policy.displayed, latest)
    }

    func testPolicyIgnoresIdleWhenNothingIsDisplayedAndUnusableRates() {
        var policy = PerformanceDisplayPolicy()
        let start = Date(timeIntervalSinceReferenceDate: 0)

        XCTAssertEqual(policy.receive(.idle, now: start), [])
        XCTAssertEqual(
            policy.receive(
                ServerPerformance(phase: .generation, tokensPerSecond: nil),
                now: start
            ),
            []
        )
        XCTAssertEqual(
            policy.receive(
                ServerPerformance(phase: .prefill, tokensPerSecond: .infinity),
                now: start
            ),
            []
        )
        XCTAssertEqual(policy.displayed, .idle)
    }

    func testPolicyResetAndAStoppingEngineDropEverythingInFlight() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let rate = ServerPerformance(phase: .generation, tokensPerSecond: 30)
        let queued = ServerPerformance(phase: .generation, tokensPerSecond: 31)
        let drops: [(inout PerformanceDisplayPolicy, Date) -> [PerformanceDisplayPolicy.Effect]] = [
            { $0.reset(now: $1) },
            { $0.receive(.idle, now: $1) },
        ]
        for drop in drops {
            var policy = PerformanceDisplayPolicy()
            XCTAssertEqual(policy.receive(rate, now: start), [.display(rate)])
            XCTAssertEqual(
                policy.receive(queued, now: start.addingTimeInterval(0.1)),
                [.schedulePublish(after: 0.4)]
            )
            XCTAssertEqual(
                drop(&policy, start.addingTimeInterval(0.2)),
                [.cancelPublish, .display(.idle)]
            )
            XCTAssertEqual(policy.publishTimerFired(now: start.addingTimeInterval(0.5)), [])
            XCTAssertEqual(drop(&policy, start.addingTimeInterval(0.6)), [])
        }
    }

    func testReaderStartsAtEOFAndHandlesTruncation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-performance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = directory.appendingPathComponent("server.log")
        try Data("old output\n".utf8).write(to: log)
        let writer = try FileHandle(forWritingTo: log)
        defer { try? writer.close() }

        let reader = ServerPerformanceLogReader()
        reader.start(path: log.path)
        XCTAssertTrue(reader.readAvailable().isEmpty)

        try writer.seekToEnd()
        try writer.write(contentsOf: Data(
            "12:00:00 Started · input 10 · cached 0 · effort absent · thinking on\n".utf8
        ))
        let started = reader.readAvailable()
        XCTAssertTrue(started.updates.isEmpty)
        XCTAssertTrue(started.sawRequestActivity, "a request start is activity without a rate")

        try writer.truncate(atOffset: 0)
        reader.rewind()
        try writer.write(contentsOf: Data(
            "12:00:09 Done · input 10 · cached 0 · output 50 · TTFT 1.0s · 29.5 tok/s\n".utf8
        ))
        let decoded = reader.readAvailable()
        XCTAssertEqual(
            decoded.updates,
            [ServerPerformance(phase: .generation, tokensPerSecond: 29.5)]
        )
        XCTAssertTrue(decoded.sawRequestActivity)
    }
}
