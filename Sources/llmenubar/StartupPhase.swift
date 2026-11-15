// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation

/// What a starting engine is doing, as far as its output says. A first start
/// of a Hugging Face model downloads it before anything loads, which can take
/// hours, and "Starting…" says nothing of that.
enum StartupPhase: Equatable, Sendable {
    /// Anything that is not a download: preparing, loading the model, warming up.
    case starting
    /// Splash is fetching the model's files.
    case downloading(Download)

    /// What a download reports, from Splash's output and the cache folder.
    struct Download: Equatable, Sendable {
        /// The repository being fetched, as `owner/repo`.
        var repository: String?
        /// The size Splash reported for what it has to fetch.
        var totalBytes: Int64?
        /// What the cache folder holds of it so far; nil until measured.
        var receivedBytes: Int64?

        /// 0 to 100, once some of it has arrived.
        var percent: Int? {
            guard let totalBytes, totalBytes > 0, let receivedBytes, receivedBytes > 0 else { return nil }
            return min(100, Int(Double(receivedBytes) / Double(totalBytes) * 100))
        }
    }

    var download: Download? {
        if case .downloading(let download) = self { return download }
        return nil
    }

    var isDownloading: Bool { download != nil }

    /// `Downloading model: 41% (9 of 22 GB)…`, or nil for a phase with no
    /// wording of its own.
    var statusText: String? {
        guard let download else { return nil }
        func gigabytes(_ bytes: Int64) -> String {
            let value = Double(bytes) / 1e9
            return value >= 10 ? String(Int(value.rounded())) : String(format: "%.1f", value)
        }
        guard let total = download.totalBytes else { return "Downloading model…" }
        if let percent = download.percent, let received = download.receivedBytes {
            return "Downloading model: \(percent)% (\(gigabytes(received)) of \(gigabytes(total)) GB)…"
        }
        return "Downloading model (\(gigabytes(total)) GB)…"
    }

    private static let launchMarker = "=== llmenubar launch"

    // The Hub download prints `Fetching 1 file(s), 21.98 GB, from …` when
    // there is something to fetch, then a progress bar that redraws one line
    // with carriage returns: `Fetching 2 files:  50%|█████     | 1/2 …`.
    private static let introPattern = try! NSRegularExpression(
        pattern: #"^Fetching \d+ file\(s\), ([0-9.]+) GB, from ([^@\s]+)"#
    )
    private static let barPattern = try! NSRegularExpression(
        pattern: #"^Fetching \d+ files?:\s+(\d{1,3})%"#
    )

    /// The phase the end of an engine's output shows. `logTail` is the last
    /// part of the log; only the current launch counts. The latest line wins:
    /// a download whose bar is the last thing written is under way, and any
    /// later output, or a bar that reached 100%, means it is over.
    /// Gigabytes read from a log line as bytes. A malformed figure (huge,
    /// infinite or not a number) is no size at all, not a trap.
    static func bytes(gigabytes: Double) -> Int64? {
        guard gigabytes.isFinite, gigabytes >= 0, gigabytes < 9e9 else { return nil }
        return Int64(gigabytes * 1e9)
    }

    static func detect(logTail: String) -> StartupPhase {
        var text = Substring(logTail)
        if let marker = logTail.range(of: launchMarker, options: .backwards) {
            text = logTail[marker.lowerBound...]
        }
        let segments = text
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = segments.last else { return .starting }

        func firstMatch(_ expression: NSRegularExpression, in line: String) -> NSTextCheckingResult? {
            expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        }
        func number(_ match: NSTextCheckingResult, in line: String) -> String? {
            Range(match.range(at: 1), in: line).map { String(line[$0]) }
        }
        func fetch(in line: String) -> Download? {
            guard let match = firstMatch(introPattern, in: line),
                  let size = number(match, in: line).flatMap(Double.init)
            else { return nil }
            let repository = Range(match.range(at: 2), in: line).map { String(line[$0]) }
            return Download(repository: repository, totalBytes: Self.bytes(gigabytes: size))
        }
        let latestFetch = segments.reversed().lazy.compactMap(fetch(in:)).first

        if let download = fetch(in: last) { return .downloading(download) }
        if let match = firstMatch(barPattern, in: last),
           let percent = number(match, in: last).flatMap(Int.init), percent < 100 {
            return .downloading(latestFetch ?? Download())
        }
        return .starting
    }
}
