// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation

/// A Splash found on this Mac, with the release it reports.
struct SplashInstall: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case homebrew
        case command
        case desktopApp
    }

    let path: String
    let kind: Kind
    /// `1.6.0`, or nil when it could not be read.
    let version: String?

    var id: String { path }

    var title: String {
        switch kind {
        case .homebrew: return "Homebrew"
        case .command: return "splash executable"
        case .desktopApp: return "Splash.app"
        }
    }

    static func kind(ofPath path: String) -> Kind {
        if path.lowercased().hasSuffix(".app") { return .desktopApp }
        // Homebrew's prefix: /opt/homebrew on Apple silicon, /usr/local on Intel.
        if path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/") { return .homebrew }
        return .command
    }

    /// The installs at the customary places, each asked for its version.
    /// Blocks while they answer, so call it off the main thread.
    static func detect() -> [SplashInstall] {
        SplashLauncher.installedPaths().map { path in
            let build = SplashDerivedState.inspectSplash(atPath: path).build
            return SplashInstall(path: path, kind: kind(ofPath: path), version: build.displayVersion)
        }
    }

    /// How often the setup window looks for an install made while it is open.
    static let watchInterval: Duration = .seconds(5)
    /// How many times a version that could not be read is asked for again, in
    /// case the install was still being written when it was first asked.
    static let unreadableVersionRetries = 3

    /// Whether the installs found by the cheap look at the customary places
    /// differ from what the window lists, so the slower look, which asks each
    /// one for its version, is worth running. An install whose version could
    /// not be read is asked again a few times, since one found mid-copy may
    /// not have been complete.
    static func needsVersionLookup(known: [SplashInstall], paths: [String], unreadableRetriesUsed: Int) -> Bool {
        if paths != known.map(\.path) { return true }
        return unreadableRetriesUsed < unreadableVersionRetries && known.contains { $0.version == nil }
    }

    static let homebrewInstallCommand = "brew install incoai/tap/splash"
    static let projectURL = URL(string: "https://github.com/incoai/splash")!
    static let releasesURL = URL(string: "https://github.com/incoai/splash/releases")!
    static let documentationURL = URL(string: "https://github.com/incoai/splash/blob/main/README.md")!
}
