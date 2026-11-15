// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation

/// How the app spells the paths it stores, shows, and hands to Splash.
///
/// Every path Splash takes is absolute. A stored path is therefore absolute
/// (or starts with `~/`), whichever directory the app was started from, and
/// is shown in the compact `~/` form.
enum PathText {
    static func expandingTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// Normalize redundant separators and dot components without turning a
    /// relative path into an absolute one.
    static func normalizing(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.hasPrefix("/") {
            return (trimmed as NSString).standardizingPath
        }
        if trimmed == "~" || trimmed.hasPrefix("~/") {
            let standardized = (trimmed as NSString).standardizingPath
            return (standardized as NSString).abbreviatingWithTildeInPath
        }

        var components: [Substring] = []
        for component in trimmed.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case ".." where components.last.map({ $0 != ".." }) == true:
                components.removeLast()
            default:
                components.append(component)
            }
        }
        return components.isEmpty ? "." : components.joined(separator: "/")
    }

    /// Store a path independently of the app's current directory.
    static func storingAbsolute(_ path: String) -> String {
        let normalized = normalizing(path)
        guard !normalized.isEmpty else { return normalized }
        let expanded = expandingTilde(normalized)
        if expanded.hasPrefix("/") {
            return normalizing(expanded)
        }
        return normalizing(
            (FileManager.default.currentDirectoryPath as NSString)
                .appendingPathComponent(expanded)
        )
    }

    /// Whether a stored path names a place independent of any working
    /// directory: it starts at the root or at the home directory.
    static func isAbsolute(_ path: String) -> Bool {
        let normalized = normalizing(path)
        return normalized.hasPrefix("/") || normalized == "~" || normalized.hasPrefix("~/")
    }

    /// Recombine a chosen folder with a file name. The folder comes from a
    /// panel and the name from a text field, because a file the app has yet to
    /// create cannot be selected.
    static func storingFile(directory: String, name: String) -> String {
        let folder = normalizing(directory)
        let file = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !file.isEmpty else { return folder }
        guard !folder.isEmpty else { return normalizing(file) }
        return normalizing((folder as NSString).appendingPathComponent(file))
    }

    /// The folder a stored file path lives in, for the row that picks it.
    static func directory(of path: String) -> String {
        (normalizing(path) as NSString).deletingLastPathComponent
    }

    /// The name a stored file path ends with, for the row that edits it.
    static func fileName(of path: String) -> String {
        (normalizing(path) as NSString).lastPathComponent
    }

    /// Present a stored path compactly without changing its identity.
    static func presenting(_ path: String) -> String {
        let normalized = normalizing(path)
        guard normalized.hasPrefix("/") else { return normalized }
        return (normalized as NSString).abbreviatingWithTildeInPath
    }

    /// Quote a word so a shell would read it back as one argument. This is for
    /// the command preview, which is displayed and never executed.
    static func shellQuoted(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let special = CharacterSet(charactersIn: " \t\n'\"\\$`|;&<>*?!()[]{}")
        if value.rangeOfCharacter(from: special) == nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
