// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation

/// The current request phase and its average throughput as reported by
/// Splash. The menu-bar rendering is deliberately eight monospaced
/// characters wide so rate changes never resize the status item.
///
/// The phase is not drawn. The menu bar shows only Splash's generation rate,
/// which arrives as a request ends, so a letter naming the phase would never
/// vary; an engine that reports both as they happen would bring the letter
/// back.
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
/// so the transitions can be exercised directly. ServerPresentation owns the
/// timer and performs whatever effects a decision returns.
///
/// A phase change is published at once and same-phase rate changes are
/// coalesced to `publishInterval`. A rate stays until the next one, or until
/// the engine stops or gives the weights back. A value that renders to the same
/// characters as the one already shown is not published at all. Requests that
/// overlap, or follow one another closely, are what make the coalescing
/// matter.
struct PerformanceDisplayPolicy {
    static let publishInterval: TimeInterval = 0.5

    enum Effect: Equatable {
        case display(ServerPerformance)
        case schedulePublish(after: TimeInterval)
        case cancelPublish
    }

    private(set) var displayed: ServerPerformance = .idle
    private var pending: ServerPerformance?
    private var lastPublish = Date.distantPast
    private var publishScheduled = false

    /// A record parsed out of the server log.
    mutating func receive(_ update: ServerPerformance, now: Date) -> [Effect] {
        if update == .idle {
            return reset(now: now)
        }
        guard update.hasDisplayableRate else { return [] }

        guard update.phase == displayed.phase else {
            // A phase change is the informative event; show it without waiting
            // out a coalescing window opened by the previous phase.
            return cancelPublish() + publish(update, now: now)
        }

        let remaining = Self.publishInterval - now.timeIntervalSince(lastPublish)
        guard remaining > 0 else {
            // Publishing now supersedes anything still queued behind a timer
            // that has come due but not yet run.
            return cancelPublish() + publish(update, now: now)
        }

        pending = update
        guard !publishScheduled else { return [] }
        publishScheduled = true
        return [.schedulePublish(after: remaining)]
    }

    mutating func publishTimerFired(now: Date) -> [Effect] {
        publishScheduled = false
        guard let update = pending else { return [] }
        pending = nil
        return publish(update, now: now)
    }

    /// The engine stopped or the weights were released. Drop everything in
    /// flight.
    mutating func reset(now: Date) -> [Effect] {
        let effects = cancelPublish()
        guard displayed != .idle else { return effects }
        return effects + publish(.idle, now: now)
    }

    // MARK: - Private

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
}

/// The latest prefill and generation rates of a run, for the status menu. The
/// two may come from different requests.
struct ServerRates: Equatable {
    var prefill: Double?
    var generation: Double?

    var isEmpty: Bool { prefill == nil && generation == nil }

    /// Takes the usable rates `newer` has and keeps the rest.
    mutating func merge(_ newer: ServerRates) {
        prefill = Self.usable(newer.prefill) ?? prefill
        generation = Self.usable(newer.generation) ?? generation
    }

    /// `rate`, unless it is no speed to show: negative, not a number, or past
    /// any an engine could reach, as a time close to zero would give.
    private static func usable(_ rate: Double?) -> Double? {
        rate.flatMap { $0 >= 0 && $0 < 1e9 ? $0 : nil }
    }

    /// `Prefill 739 t/s · Generation 74.2 t/s`, without a rate not yet known.
    var menuDescription: String? {
        let parts = [("Prefill", prefill), ("Generation", generation)].compactMap { name, rate in
            Self.usable(rate).map { "\(name) \(Self.describe($0)) t/s" }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// One decimal below 100, and whole numbers with commas from there, in
    /// every locale.
    private static func describe(_ rate: Double) -> String {
        guard rate >= 99.95 else {
            return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), rate)
        }
        return NativeContextWindow.grouped(Int(rate.rounded()))
    }
}

/// Incremental line parser for the request records Splash writes to its
/// console. It retains a partial final line because a filesystem write event is
/// not a promise that the newest line was written in one operation.
///
/// Splash prints a line when a request starts, another at its first token and
/// a third when it ends:
///
///     19:17:29 Started · request 7 · input 3,315 · cached 224 · effort absent · thinking on
///     19:17:33 TTFT of request 7: 3545.02 ms: own prefill 3544, claim wait 0, ...
///     19:17:40 Done · request 7 · input 3,315 · cached 224 · output 759 · TTFT 3.5s · 74.2 tok/s
///
/// The rate on the end line is the request's generation speed. Splash prints no
/// prefill speed: it is the input the cache did not hold, over the time the
/// request's own prefill took.
struct ServerPerformanceLogParser {
    private var buffered = Data()

    /// True when the last `ingest` saw request work. A start line carries no
    /// rate but still means the server was asked to do something.
    private(set) var sawRequestActivity = false

    /// The last change to the weights' residency in the bytes of the last
    /// `ingest`, if there was one.
    private(set) var weightsEvent: WeightsEvent?

    /// The last prefill and generation rates in the bytes of the last `ingest`.
    private(set) var rates = ServerRates()

    /// The tokens each started request has to prefill, by request number, until
    /// its first token or its end.
    private var uncachedTokens: [Int: Int] = [:]

    mutating func ingest(_ data: Data) -> [ServerPerformance] {
        buffered.append(data)
        sawRequestActivity = false
        weightsEvent = nil
        rates = ServerRates()
        var updates: [ServerPerformance] = []

        while let newline = buffered.firstIndex(of: 0x0a) {
            let lineData = buffered[..<newline]
            buffered.removeSubrange(...newline)
            let line = String(decoding: lineData, as: UTF8.self)
            guard let record = Self.record(in: line) else { continue }
            if record.isRequestWork { sawRequestActivity = true }
            if let event = record.weights { weightsEvent = event }
            if let update = record.update {
                updates.append(update)
                rates.merge(ServerRates(generation: update.tokensPerSecond))
            }
            if let start = record.started { uncachedTokens[start.request] = start.uncachedTokens }
            if let first = record.firstToken,
               let tokens = uncachedTokens.removeValue(forKey: first.request),
               tokens > 0, first.prefillMilliseconds > 0 {
                rates.merge(ServerRates(prefill: Double(tokens) * 1_000 / first.prefillMilliseconds))
            }
            if let ended = record.endedRequest { uncachedTokens[ended] = nil }
            if record.stopsServer { uncachedTokens.removeAll() }
        }
        return updates
    }

    mutating func reset() {
        buffered.removeAll(keepingCapacity: true)
        sawRequestActivity = false
        weightsEvent = nil
        rates = ServerRates()
        uncachedTokens.removeAll()
    }

    private struct Record {
        let isRequestWork: Bool
        let update: ServerPerformance?
        var weights: WeightsEvent?
        var started: (request: Int, uncachedTokens: Int)?
        var firstToken: (request: Int, prefillMilliseconds: Double)?
        var endedRequest: Int?
        var stopsServer = false

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
        if message.hasPrefix("TTFT of request ") {
            var record = Record(isRequestWork: true, update: nil)
            record.firstToken = firstToken(in: message)
            return record
        }
        let fields = message.components(separatedBy: " · ")
        let request = count("request ", in: fields)
        switch fields.first {
        case "Started":
            var record = Record(isRequestWork: true, update: nil)
            if let request,
               let input = count("input ", in: fields),
               let cached = count("cached ", in: fields) {
                record.started = (request, input - cached)
            }
            return record
        case "Done":
            let rate = fields.lazy.compactMap(generationRate).first
            let update = rate.map { ServerPerformance(phase: .generation, tokensPerSecond: $0) }
            var record = Record(isRequestWork: true, update: update)
            record.endedRequest = request
            return record
        case "Cancelled":
            var record = Record(isRequestWork: true, update: nil)
            record.endedRequest = request
            return record
        case "Error":
            guard let request else { return nil }
            var record = Record(isRequestWork: false, update: nil)
            record.endedRequest = request
            return record
        case "Stopping":
            var record = Record(isRequestWork: false, update: .idle)
            record.stopsServer = true
            return record
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

    /// The whole number of the field that starts with `label`, as in
    /// `input 3,315`.
    private static func count(_ label: String, in fields: [String]) -> Int? {
        fields.first { $0.hasPrefix(label) }
            .flatMap { Int($0.dropFirst(label.count).replacingOccurrences(of: ",", with: "")) }
    }

    /// `TTFT of request 7: 3545.02 ms: own prefill 3544, claim wait 0, ...`
    private static func firstToken(in message: Substring) -> (request: Int, prefillMilliseconds: Double)? {
        let tail = message.dropFirst("TTFT of request ".count)
        guard let colon = tail.firstIndex(of: ":"),
              let request = Int(tail[..<colon]),
              let label = tail.range(of: "own prefill "),
              let milliseconds = Double(tail[label.upperBound...].prefix { $0 != "," }),
              milliseconds.isFinite
        else { return nil }
        return (request, milliseconds)
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
    var rates = ServerRates()

    var isEmpty: Bool { updates.isEmpty && !sawRequestActivity && weights == nil && rates.isEmpty }
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
                weights: parser.weightsEvent,
                rates: parser.rates
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
