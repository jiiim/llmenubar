// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation

enum ServerLogDiagnostics {
    /// The server diagnostic for the most recent failed launch. Splash's
    /// argument parser prints its usage first and the complaint last, and a
    /// Python failure ends with the exception, so the last line that reads as a
    /// diagnostic is the one worth reporting; failing that, the last line.
    static func launchFailureReason(logPath: String) -> String {
        let lines = recentLogLines(logPath: logPath)
        guard !lines.isEmpty else { return "" }

        let launchStart = lines.lastIndex(where: {
            $0.hasPrefix("=== llmenubar launch ")
        })
        let currentLaunch = launchStart.map { lines.dropFirst($0 + 1) } ?? lines[...]
        let output = currentLaunch.filter { !Self.isLaunchMetadata($0) }
        guard !output.isEmpty else { return "" }

        let diagnosticTerms = [
            "error", "fatal", "fail", "unknown", "invalid", "unsupported",
            "not found", "no such file", "unable", "cannot", "couldn", "missing",
            "refuse",
        ]
        if let diagnostic = output.last(where: { line in
            let lowercased = line.lowercased()
            return !lowercased.hasPrefix("usage:") && diagnosticTerms.contains(where: lowercased.contains)
        }) {
            return diagnostic
        }
        return output.last ?? ""
    }

    /// The last meaningful line of the log — usually the fatal message for a
    /// process that had already reached its running state.
    static func lastLogReason(logPath: String) -> String {
        recentLogLines(logPath: logPath)
            .filter { !Self.isLaunchMetadata($0) }
            .last ?? ""
    }

    /// The last 64 KB of the log, undecoded lines and all.
    static func logTail(logPath: String) -> String {
        let path = (logPath as NSString).expandingTildeInPath
        // Read only the tail: the log can grow large. A first line sliced by
        // the byte window is harmless — lossy UTF-8 decoding tolerates it.
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        let tailBytes: UInt64 = 64 * 1024
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > tailBytes ? end - tailBytes : 0)
        guard let data = try? handle.readToEnd() else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The longest line a diagnostic can be. The reason goes into a menu item,
    /// an alert and notifications; the whole text stays in the log.
    static let maximumLineLength = 200

    /// Lines end at a newline or a carriage return: a download's progress
    /// redraws one line with `\r`, and without the split a whole transfer is
    /// one enormous line.
    private static func recentLogLines(logPath: String) -> [String] {
        let content = logTail(logPath: logPath)
        return content
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map(bounded)
    }

    static func bounded(_ line: String) -> String {
        line.count > maximumLineLength ? String(line.prefix(maximumLineLength - 1)) + "…" : line
    }

    private static func isLaunchMetadata(_ line: String) -> Bool {
        line.hasPrefix("===") || line.hasPrefix("exec:") ||
            line.hasPrefix("cwd:") || line.hasPrefix("env:") ||
            line.hasPrefix("argv:") || line == "---"
    }

}
