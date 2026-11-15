// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation

/// What the selected `splash` executable says about itself: that it is Splash,
/// which release, and which `serve` options it takes.
///
/// Splash ships often and gains options between releases. The app reads the
/// answer from the executable each time instead of remembering a version, so a
/// Splash upgraded or rebuilt between launches is judged as it is now.
struct SplashBuild: Equatable, Sendable {
    enum Identity: Equatable, Sendable {
        /// Not inspected yet, or the executable could not be run.
        case unknown
        /// Ran, and is not Splash.
        case notSplash
        /// `Splash 1.5.0`, or `Splash (source checkout)`.
        case splash(version: String)
    }

    var identity: Identity
    /// Every `--option` named in `splash serve --help`. Empty when it could
    /// not be read.
    var serveFlags: Set<String>

    static let unknown = SplashBuild(identity: .unknown, serveFlags: [])

    var isSplash: Bool {
        if case .splash = identity { return true }
        return false
    }

    /// `1.5.0`, or `source checkout`.
    var displayVersion: String? {
        guard case .splash(let version) = identity else { return nil }
        return version
    }

    /// Whether `serve` takes `flag`. A build that could not be inspected is
    /// given the benefit of the doubt: the launch itself reports an option the
    /// executable refuses.
    func supports(_ flag: String) -> Bool {
        guard isSplash, !serveFlags.isEmpty else { return true }
        return serveFlags.contains(flag)
    }

    // MARK: Parsing

    static func parseIdentity(fromVersionOutput output: String) -> Identity {
        let line = output
            .split(whereSeparator: \.isNewline)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard line.hasPrefix("Splash") else { return .notSplash }
        let rest = line.dropFirst("Splash".count).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("("), rest.hasSuffix(")") {
            return .splash(version: String(rest.dropFirst().dropLast()))
        }
        // A release starts with a number: `1.6.0`, or a build between releases
        // such as `1.5.0-42-g705ad7ac`. Any other word after the name is some
        // other program that happens to start with the same letters.
        guard rest.first?.isNumber == true,
              rest.allSatisfy({ !$0.isWhitespace })
        else { return .notSplash }
        return .splash(version: rest)
    }

    private static let optionPattern = try! NSRegularExpression(
        pattern: "(?<![A-Za-z0-9-])--[a-z][a-z0-9]*(?:-[a-z0-9]+)*"
    )

    static func parseServeFlags(fromHelp help: String) -> Set<String> {
        let range = NSRange(help.startIndex..., in: help)
        var flags = Set<String>()
        for match in optionPattern.matches(in: help, range: range) {
            if let swiftRange = Range(match.range, in: help) {
                flags.insert(String(help[swiftRange]))
            }
        }
        return flags
    }

    // MARK: Inspection

    /// Run the executable and read what it reports. Blocks for at most a few
    /// seconds per question, so call it off the main thread.
    static func inspecting(path: String) -> SplashBuild {
        guard case .success(let launcher) = SplashLauncher.resolve(path: path) else { return .unknown }
        return inspecting(launcher: launcher)
    }

    static func inspecting(launcher: SplashLauncher) -> SplashBuild {
        func ask(_ arguments: [String]) -> CommandOutput? {
            run(launcher.executable, launcher.leadingArguments + arguments, environment: launcher.environment, timeout: 10)
        }
        guard let version = ask(["--version"]) else { return .unknown }
        // A program that refuses `--version` is not Splash.
        guard version.status == 0 else { return SplashBuild(identity: .notSplash, serveFlags: []) }
        let identity = parseIdentity(fromVersionOutput: version.output)
        guard case .splash = identity else {
            return SplashBuild(identity: identity, serveFlags: [])
        }
        let help = ask(["serve", "--help"])
        let flags = help.flatMap { $0.status == 0 ? parseServeFlags(fromHelp: $0.output) : nil } ?? []
        return SplashBuild(identity: identity, serveFlags: flags)
    }

    struct CommandOutput: Sendable {
        let status: Int32
        let output: String
    }

    /// Run `executable` with `arguments`, giving up after `timeout` seconds.
    /// Output goes to a private temporary file rather than a pipe, so a program
    /// that writes more than a pipe holds cannot stall waiting to be read.
    static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String] = [:],
        timeout: TimeInterval
    ) -> CommandOutput? {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-inspect-\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: outputURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ), let output = try? FileHandle(forWritingTo: outputURL) else { return nil }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, added in added }
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 0.2) != .success {
                // The process has not been reaped, so its PID still belongs to
                // this invocation. Bound inspection cleanup even if TERM is ignored.
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
            return nil
        }

        try? output.synchronize()
        guard let reader = try? FileHandle(forReadingFrom: outputURL) else { return nil }
        defer { try? reader.close() }
        let data = (try? reader.read(upToCount: 256 * 1_024)) ?? Data()
        return CommandOutput(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
