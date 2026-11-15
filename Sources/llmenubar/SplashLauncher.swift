// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation

/// How a chosen Splash is run.
///
/// Most installs have a `splash` command: Homebrew's, or the `splash` file of a
/// source checkout. The Splash desktop app has none. It carries the Python
/// runtime and Splash's launcher inside its bundle and starts the server by
/// running the launcher with that Python, so choosing `Splash.app` runs the
/// same command the app does. Both give the same `splash serve` behavior and
/// share the models the desktop app has installed.
struct SplashLauncher: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case command
        case desktopApp
    }

    let kind: Kind
    /// The program to start.
    let executable: String
    /// Arguments that come before `serve`: for the desktop app, the launcher
    /// script and the flags Splash itself starts it with.
    let leadingArguments: [String]
    /// Variables the program needs added to the environment it inherits.
    let environment: [String: String]

    /// Why a chosen path cannot be run.
    enum Issue: Error, Equatable, Sendable {
        case notAnExecutable
        case folder
        case appWithoutRuntime

        var message: String {
            switch self {
            case .notAnExecutable: return "Choose an executable splash file, or Splash.app."
            case .folder: return "Choose the splash file itself, not a folder."
            case .appWithoutRuntime: return "That app does not contain a Splash runtime."
            }
        }
    }

    /// The launcher for the file or app at `path`.
    static func resolve(path: String) -> Result<SplashLauncher, Issue> {
        let resolved = PathText.expandingTilde(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory) else {
            return .failure(.notAnExecutable)
        }
        if isDirectory.boolValue {
            guard resolved.lowercased().hasSuffix(".app") else { return .failure(.folder) }
            return desktopApp(at: resolved)
        }
        guard FileManager.default.isExecutableRegularFile(atPath: resolved) else {
            return .failure(.notAnExecutable)
        }
        return .success(SplashLauncher(kind: .command, executable: resolved, leadingArguments: [], environment: [:]))
    }

    private static func desktopApp(at app: String) -> Result<SplashLauncher, Issue> {
        let runtime = (app as NSString).appendingPathComponent("Contents/Resources/splash")
        let python = (runtime as NSString).appendingPathComponent("python/bin/python3")
        let launcher = (runtime as NSString).appendingPathComponent("install/launcher.py")
        guard FileManager.default.isExecutableRegularFile(atPath: python),
              FileManager.default.isReadableRegularFile(atPath: launcher)
        else { return .failure(.appWithoutRuntime) }
        // The flags the app starts the launcher with: isolated from the user's
        // Python settings and site-packages, unbuffered, and never writing
        // bytecode into the signed bundle.
        return .success(SplashLauncher(
            kind: .desktopApp,
            executable: python,
            leadingArguments: ["-I", "-B", "-u", launcher],
            environment: ["PYTHONNOUSERSITE": "1"]
        ))
    }

    /// The program and its arguments, as one command line.
    func commandLine(_ arguments: [String]) -> [String] {
        [executable] + leadingArguments + arguments
    }

    // MARK: Finding installs

    /// Where a `splash` command usually is, then where the desktop app is.
    static let customaryPaths = [
        "/opt/homebrew/bin/splash",
        "/usr/local/bin/splash",
        "~/.local/bin/splash",
        "/Applications/Splash.app",
        "~/Applications/Splash.app",
    ]

    /// What to call the install at `path` in a sentence.
    static func description(ofPath path: String) -> String {
        path.lowercased().hasSuffix(".app")
            ? "Splash.app at \(PathText.presenting(path))"
            : "splash at \(PathText.presenting(path))"
    }

    /// The installs found on this Mac, in the order they are preferred, as
    /// absolute paths.
    static func installedPaths() -> [String] {
        customaryPaths.compactMap { candidate in
            let path = PathText.expandingTilde(candidate)
            if case .success = resolve(path: path) { return path }
            return nil
        }
    }
}
