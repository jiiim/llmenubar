// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation

/// Where Hugging Face models download to, and what it takes to put one there.
///
/// Splash downloads into the Hugging Face cache: `HF_HUB_CACHE`, else `hub`
/// under `HF_HOME`, else `~/.cache/huggingface/hub`. LLMenuBar can set
/// `HF_HUB_CACHE` itself; without that it uses what the user already has
/// configured for Hugging Face.
enum ModelCache {
    /// What decided the location.
    enum Source: Hashable, Sendable {
        /// The folder chosen in LLMenuBar.
        case llmenubar
        /// A Hugging Face variable, set in LLMenuBar's environment setting, in
        /// the login session or in the user's shell.
        case variable(String)
        case huggingFaceDefault

        /// `HF_HOME`, for a location a variable named.
        var variableName: String? {
            if case .variable(let name) = self { return name }
            return nil
        }

        var caption: String {
            switch self {
            case .llmenubar: return "Set in LLMenuBar."
            case .variable(let name): return "From your Hugging Face setting, \(name)."
            case .huggingFaceDefault: return "The Hugging Face default."
            }
        }
    }

    struct Location: Hashable, Sendable {
        /// An absolute path.
        let path: String
        let source: Source
    }

    /// The cache Splash will download into. `environmentText` is the
    /// environment setting's lines and `process` is what the app inherited,
    /// which Splash inherits too. The user's shell profile is not consulted
    /// here: it is read once, at setup, and saved as the setting.
    static func effectiveLocation(
        setting: String,
        environmentText: String,
        process: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> Location {
        let chosen = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        if !chosen.isEmpty {
            return Location(path: absolute(chosen, home: home), source: .llmenubar)
        }
        // The environment setting is merged over what the app inherited.
        var variables = process
        for assignment in EnvironmentText.parse(environmentText) { variables[assignment.name] = assignment.value }
        return location(fromVariables: variables, home: home)
            ?? Location(path: home + "/.cache/huggingface/hub", source: .huggingFaceDefault)
    }

    /// The cache a set of Hugging Face variables names, or nil when they name
    /// none: `HF_HUB_CACHE`, else `hub` under `HF_HOME`, else under
    /// `XDG_CACHE_HOME`.
    static func location(fromVariables variables: [String: String], home: String = NSHomeDirectory()) -> Location? {
        func value(_ name: String) -> String? {
            variables[name].map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        if let cache = value("HF_HUB_CACHE") {
            return Location(path: absolute(cache, home: home), source: .variable("HF_HUB_CACHE"))
        }
        if let hfHome = value("HF_HOME") {
            return Location(path: absolute(hfHome, home: home) + "/hub", source: .variable("HF_HOME"))
        }
        if let xdg = value("XDG_CACHE_HOME") {
            return Location(path: absolute(xdg, home: home) + "/huggingface/hub", source: .variable("XDG_CACHE_HOME"))
        }
        return nil
    }

    private static func absolute(_ path: String, home: String) -> String {
        var expanded = path
        if expanded == "~" { expanded = home } else if expanded.hasPrefix("~/") { expanded = home + expanded.dropFirst() }
        return (expanded as NSString).standardizingPath
    }

    // MARK: Disk

    /// The bytes free on the volume that holds `path`, or nil when its volume is
    /// not mounted. A folder not made yet is judged by the nearest one that
    /// exists.
    static func freeBytes(at path: String) -> Int64? {
        var candidate = path
        while !candidate.isEmpty, !FileManager.default.fileExists(atPath: candidate) {
            let parent = (candidate as NSString).deletingLastPathComponent
            if parent == candidate { return nil }
            candidate = parent
        }
        guard !candidate.isEmpty else { return nil }
        // Under /Volumes, a volume that is not mounted must not read as the
        // boot disk's space.
        let components = (path as NSString).pathComponents
        if components.count > 2, components[1] == "Volumes",
           !FileManager.default.fileExists(atPath: "/Volumes/" + components[2]) {
            return nil
        }
        // "Important usage" counts space macOS could purge; a download cannot
        // use that, and `df` does not show it. Take the smaller of the two.
        let values = try? URL(fileURLWithPath: candidate).resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ])
        let readings = [
            values?.volumeAvailableCapacityForImportantUsage,
            values?.volumeAvailableCapacity.map(Int64.init),
        ].compactMap { $0 }
        return readings.min()
    }

    /// `models--owner--repo`, how the cache names a repository's folder.
    static func repositoryFolder(_ repository: String) -> String {
        "models--" + repository.replacingOccurrences(of: "/", with: "--")
    }

    /// Whether `file` of `repository` is already in the cache, under any
    /// revision.
    static func holds(_ file: String, of repository: String, in cache: String, commit: String? = nil) -> Bool {
        let snapshots = "\(cache)/\(repositoryFolder(repository))/snapshots"
        if let commit {
            guard !commit.isEmpty, commit.allSatisfy({ $0.isHexDigit }) else { return false }
            return FileManager.default.fileExists(atPath: "\(snapshots)/\(commit)/\(file)")
        }
        guard let revisions = try? FileManager.default.contentsOfDirectory(atPath: snapshots) else { return false }
        return revisions.contains { FileManager.default.fileExists(atPath: "\(snapshots)/\($0)/\(file)") }
    }

    // MARK: Progress

    /// The bytes a download has written since `since`: the partial files in the
    /// repository's blobs folder, and the blobs that finished after it began.
    /// Hugging Face's Xet transport can hold a file's bytes in memory for
    /// minutes before writing them, so this can lag the network.
    static func receivedBytes(repository: String, in cache: String, since: Date) -> Int64 {
        let blobs = "\(cache)/\(repositoryFolder(repository))/blobs"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: blobs) else { return 0 }
        // A little before the start, for clocks and for a file created as the
        // launch began.
        let cutoff = since.addingTimeInterval(-5)
        var total: Int64 = 0
        for name in names {
            let url = URL(fileURLWithPath: "\(blobs)/\(name)")
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified >= cutoff
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

// MARK: - The login shell's environment

/// The Hugging Face variables the user's shell sets. A person who moved their
/// Hugging Face cache did it in a shell profile, which an app started from the
/// Dock never reads. Setup asks a login shell once, so the folder they meant
/// can be offered and saved; nothing reads the shell after that.
enum LoginShellEnvironment {
    static let names: Set<String> = ["HF_HUB_CACHE", "HF_HOME", "XDG_CACHE_HOME"]

    private static let begin = "__LLMENUBAR_ENV_BEGIN__"
    private static let end = "__LLMENUBAR_ENV_END__"

    /// The wanted variables in `output`, which a shell may surround with
    /// banners and warnings of its own: only the lines between the markers count.
    static func parse(_ output: String) -> [String: String] {
        guard let start = output.range(of: begin + "\n"),
              let stop = output.range(of: "\n" + end, range: start.upperBound..<output.endIndex)
        else { return [:] }
        var found: [String: String] = [:]
        for line in output[start.upperBound..<stop.lowerBound].split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<equals])
            if names.contains(name) { found[name] = String(line[line.index(after: equals)...]) }
        }
        return found
    }

    /// Ask the login shell, as Terminal starts one. Blocks for up to `timeout`
    /// seconds; call it off the main thread.
    static func probe(timeout: TimeInterval = 5) -> [String: String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let script = "echo \(begin); /usr/bin/env; echo \(end)"
        guard let result = SplashBuild.run(shell, ["-i", "-l", "-c", script], timeout: timeout) else { return [:] }
        return parse(result.output)
    }

    /// The cache the shell sets, when the app did not inherit one: an
    /// inherited setting is already in Splash's environment and needs no copy.
    static func cacheLocation(
        inheriting inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> ModelCache.Location? {
        guard names.allSatisfy({ inherited[$0] == nil }) else { return nil }
        return ModelCache.location(fromVariables: probe())
    }
}
