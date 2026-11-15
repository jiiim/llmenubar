// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation

/// The current request phase and its average throughput as reported by
/// Splash. The menu-bar rendering is deliberately eight monospaced
/// characters wide so rate changes never resize the status item.
///
/// The phase is not drawn. Splash reports only a generation rate, so a letter
/// naming the phase would never vary; an engine that reports prefill as well
/// would bring the letter back.
struct ServerPerformance: Equatable {
    enum Phase: String {
        case idle = "-"
        case prefill = "P"
        case generation = "G"
    }

    let phase: Phase
    let tokensPerSecond: Double?

    static let idle = ServerPerformance(phase: .idle, tokensPerSecond: nil)

    var menuBarRate: String {
        hasDisplayableRate ? Self.rateField(tokensPerSecond) : "----"
    }

    var menuBarText: String {
        "\(menuBarRate) t/s"
    }

    var hasDisplayableRate: Bool {
        phase != .idle && Self.isDisplayable(tokensPerSecond)
    }

    /// The rendered rate field, which is everything the menu bar shows.
    /// Splash reports more precision than four columns can display, so
    /// consecutive records can reduce to the same identity — and replacing one
    /// with another of those changes nothing on screen.
    struct DisplayIdentity: Equatable {
        let rate: String
    }

    var displayIdentity: DisplayIdentity {
        DisplayIdentity(rate: menuBarRate)
    }

    /// Four columns at every magnitude. Prefill rates can exceed 1,000 t/s,
    /// so compact notation avoids widening the menu-bar item on fast hardware.
    static func rateField(_ rate: Double?) -> String {
        guard let rate, isDisplayable(rate) else { return "----" }
        switch rate {
        case ..<99.95:
            return String(format: "%4.1f", locale: Locale(identifier: "en_US_POSIX"), rate)
        case ..<999.5:
            return String(format: "%4.0f", locale: Locale(identifier: "en_US_POSIX"), rate)
        case ..<9_950:
            return String(format: "%3.1fk", locale: Locale(identifier: "en_US_POSIX"), rate / 1_000)
        case ..<99_500:
            return String(format: "%3.0fk", locale: Locale(identifier: "en_US_POSIX"), rate / 1_000)
        default:
            return "99k+"
        }
    }

    private static func isDisplayable(_ rate: Double?) -> Bool {
        guard let rate else { return false }
        return rate.isFinite && rate >= 0
    }
}

/// When the menu bar is allowed to change, expressed without timers or a clock
/// so the transitions can be exercised directly. ServerManager owns the two
/// timers and performs whatever effects a decision returns.
///
/// A request's rate is on screen only while the display is held, so: publish a
/// phase change at once, coalesce same-phase rate changes to
/// `publishInterval`, and when a request ends hold its final rate for
/// `holdInterval` instead of blanking the display immediately. A value that
/// renders to the same characters as the one already shown is not published at
/// all. Requests that overlap, or follow one another within the hold, are what
/// make the coalescing matter.
struct PerformanceDisplayPolicy {
    static let publishInterval: TimeInterval = 0.5
    static let holdInterval: TimeInterval = 6.0

    enum Effect: Equatable {
        case display(ServerPerformance)
        case schedulePublish(after: TimeInterval)
        case cancelPublish
        case scheduleIdle(after: TimeInterval)
        case cancelIdle
    }

    private(set) var displayed: ServerPerformance = .idle
    private var pending: ServerPerformance?
    private var lastPublish = Date.distantPast
    private var publishScheduled = false
    private var idleScheduled = false

    /// A record parsed out of the server log.
    mutating func receive(_ update: ServerPerformance, now: Date) -> [Effect] {
        if update == .idle {
            return holdBeforeIdle(now: now)
        }
        guard update.hasDisplayableRate else { return [] }

        var effects = cancelIdle()
        guard update.phase == displayed.phase else {
            // A phase change is the informative event; show it without waiting
            // out a coalescing window opened by the previous phase.
            return effects + cancelPublish() + publish(update, now: now)
        }

        let remaining = Self.publishInterval - now.timeIntervalSince(lastPublish)
        guard remaining > 0 else {
            // Publishing now supersedes anything still queued behind a timer
            // that has come due but not yet run.
            return effects + cancelPublish() + publish(update, now: now)
        }

        pending = update
        if !publishScheduled {
            publishScheduled = true
            effects.append(.schedulePublish(after: remaining))
        }
        return effects
    }

    mutating func publishTimerFired(now: Date) -> [Effect] {
        publishScheduled = false
        guard let update = pending else { return [] }
        pending = nil
        return publish(update, now: now)
    }

    mutating func idleTimerFired(now: Date) -> [Effect] {
        idleScheduled = false
        return publish(.idle, now: now)
    }

    /// The user turned the display off. Drop everything in flight.
    mutating func reset(now: Date) -> [Effect] {
        let effects = cancelPublish() + cancelIdle()
        guard displayed != .idle else { return effects }
        return effects + publish(.idle, now: now)
    }

    // MARK: - Private

    private mutating func holdBeforeIdle(now: Date) -> [Effect] {
        var effects: [Effect] = []
        if let queued = pending {
            // The request's final rate is the one worth showing; do not let a
            // coalescing window swallow it.
            effects += cancelPublish() + publish(queued, now: now)
        }
        // `displayed` only ever holds .idle or a value that passed
        // hasDisplayableRate, so this is the already-idle case: nothing to
        // hold, and nothing to blank.
        guard displayed.hasDisplayableRate else { return effects }
        guard !idleScheduled else { return effects }
        idleScheduled = true
        return effects + [.scheduleIdle(after: Self.holdInterval)]
    }

    private mutating func publish(
        _ update: ServerPerformance,
        now: Date
    ) -> [Effect] {
        let wasDisplaying = displayed.displayIdentity
        displayed = update
        lastPublish = now
        // The coalescing window is still consumed — this counts as the publish
        // for this interval — but a value that renders and reads identically
        // gives the menu bar nothing to redraw.
        guard update.displayIdentity != wasDisplaying else { return [] }
        return [.display(update)]
    }

    private mutating func cancelPublish() -> [Effect] {
        pending = nil
        guard publishScheduled else { return [] }
        publishScheduled = false
        return [.cancelPublish]
    }

    private mutating func cancelIdle() -> [Effect] {
        guard idleScheduled else { return [] }
        idleScheduled = false
        return [.cancelIdle]
    }
}

/// Incremental line parser for the request records Splash writes to its
/// console. It retains a partial final line because a filesystem write event is
/// not a promise that the newest line was written in one operation.
///
/// Splash prints a line when a request starts and another when it ends:
///
///     19:17:29 Started · input 131 · cached 0 · effort absent · thinking on
///     19:17:40 Done · input 131 · cached 0 · output 759 · TTFT 1.0s · 74.2 tok/s
///
/// The rate on the end line is the request's generation speed. Splash reports
/// no prefill speed in its log, so the display shows generation only.
struct ServerPerformanceLogParser {
    private var buffered = Data()

    /// True when the last `ingest` saw request work. A start line carries no
    /// rate but still means the server was asked to do something.
    private(set) var sawRequestActivity = false

    /// The last change to the weights' residency in the bytes of the last
    /// `ingest`, if there was one.
    private(set) var weightsEvent: WeightsEvent?

    mutating func ingest(_ data: Data) -> [ServerPerformance] {
        buffered.append(data)
        sawRequestActivity = false
        weightsEvent = nil
        var updates: [ServerPerformance] = []

        while let newline = buffered.firstIndex(of: 0x0a) {
            let lineData = buffered[..<newline]
            buffered.removeSubrange(...newline)
            let line = String(decoding: lineData, as: UTF8.self)
            guard let record = Self.record(in: line) else { continue }
            if record.isRequestWork { sawRequestActivity = true }
            if let event = record.weights { weightsEvent = event }
            if let update = record.update { updates.append(update) }
        }
        return updates
    }

    mutating func reset() {
        buffered.removeAll(keepingCapacity: true)
        sawRequestActivity = false
        weightsEvent = nil
    }

    private struct Record {
        let isRequestWork: Bool
        let update: ServerPerformance?
        var weights: WeightsEvent?

        init(isRequestWork: Bool, update: ServerPerformance?, weights: WeightsEvent? = nil) {
            self.isRequestWork = isRequestWork
            self.update = update
            self.weights = weights
        }
    }

    /// Console lines read `HH:MM:SS message`; the message's first word names
    /// the event.
    private static func record(in line: String) -> Record? {
        guard let message = message(in: line) else { return nil }
        // The weights are given back after an idle spell, or on request, and
        // come back with the next request:
        //
        //     03:56:13 Weights released after 600 s without a request; the next request restores them
        //     03:58:02 Weights restored in 1.84 s
        //
        // A failed restore leaves them released.
        if message.hasPrefix("Weights released") || message.hasPrefix("Weights not restored") {
            return Record(isRequestWork: false, update: nil, weights: .released)
        }
        if message.hasPrefix("Weights restored") {
            return Record(isRequestWork: false, update: nil, weights: .restored)
        }
        let fields = message.components(separatedBy: " · ")
        switch fields.first {
        case "Started":
            return Record(isRequestWork: true, update: nil)
        case "Done":
            let rate = fields.lazy.compactMap(generationRate).first
            let update = rate.map { ServerPerformance(phase: .generation, tokensPerSecond: $0) }
            return Record(isRequestWork: true, update: update ?? .idle)
        case "Cancelled":
            return Record(isRequestWork: true, update: .idle)
        case "Stopping":
            return Record(isRequestWork: false, update: .idle)
        default:
            return nil
        }
    }

    private static func message(in line: String) -> Substring? {
        // `12:34:56 ` is nine characters with a colon in the third and sixth.
        let characters = Array(line.prefix(9))
        guard characters.count == 9,
              characters[2] == ":", characters[5] == ":", characters[8] == " ",
              [0, 1, 3, 4, 6, 7].allSatisfy({ characters[$0].isASCII && characters[$0].isNumber })
        else { return nil }
        return line.dropFirst(9)
    }

    private static func generationRate(_ field: String) -> Double? {
        let suffix = " tok/s"
        guard field.hasSuffix(suffix),
              let value = Double(field.dropLast(suffix.count)),
              value.isFinite, value >= 0
        else { return nil }
        return value
    }
}

/// A change to whether the engine holds the model's weights in memory.
enum WeightsEvent: Equatable {
    case released
    case restored
}

/// One read of appended log bytes: the rate records parsed, and whether the
/// bytes described request work at all. A request that only logged its start
/// is activity even though it yields no displayable rate.
struct ServerLogBatch: Equatable {
    var updates: [ServerPerformance] = []
    var sawRequestActivity = false
    var weights: WeightsEvent?

    var isEmpty: Bool { updates.isEmpty && !sawRequestActivity && weights == nil }
}

/// Reads only bytes appended after monitoring starts. Rotation and log clearing
/// truncate the active inode, so a smaller file resets both the offset and any
/// partial line left by the prior contents.
///
/// Unchecked because the confinement is by queue, not by type: every caller in
/// ProcessManager touches this only inside `performanceQueue.async`, which is
/// serial, so the file handle, offset, and parser are never reached
/// concurrently. Any new call site must hold to that.
final class ServerPerformanceLogReader: @unchecked Sendable {
    private var handle: FileHandle?
    private var offset: UInt64 = 0
    private var parser = ServerPerformanceLogParser()

    func start(path: String) {
        stop()
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)),
              let end = try? handle.seekToEnd()
        else { return }
        self.handle = handle
        offset = end
    }

    func readAvailable() -> ServerLogBatch {
        guard let handle else { return ServerLogBatch() }
        do {
            let end = try handle.seekToEnd()
            if end < offset {
                offset = 0
                parser.reset()
            }
            guard end > offset else { return ServerLogBatch() }
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            offset += UInt64(data.count)
            let updates = parser.ingest(data)
            return ServerLogBatch(
                updates: updates,
                sawRequestActivity: parser.sawRequestActivity,
                weights: parser.weightsEvent
            )
        } catch {
            return ServerLogBatch()
        }
    }

    func rewind() {
        offset = 0
        parser.reset()
    }

    func stop() {
        try? handle?.close()
        handle = nil
        offset = 0
        parser.reset()
    }
}
