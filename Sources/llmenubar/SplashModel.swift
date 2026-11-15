// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation

/// How a model is named to Splash: a Hugging Face model ID, or files on this
/// Mac that `splash serve --model-dir` loads under a name of its own.
enum SplashModel {
    // The rules `splash serve --model` applies, so a mistake is shown beside
    // the field instead of in a failed launch.
    private static let repositoryPattern = try! NSRegularExpression(
        pattern: "^[A-Za-z0-9_](?:[A-Za-z0-9._-]*[A-Za-z0-9_])?/[A-Za-z0-9_](?:[A-Za-z0-9._-]{0,94}[A-Za-z0-9_])?$"
    )
    private static let variantPattern = try! NSRegularExpression(
        pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"
    )

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// `owner/repo`, the Hugging Face repository that holds a model or draft.
    static func isRepositoryID(_ text: String) -> Bool {
        matches(repositoryPattern, text)
            && !text.contains("--")
            && !text.contains("..")
            && !text.hasSuffix(".git")
    }

    /// `owner/repo` or `owner/repo:VARIANT`, such as
    /// `unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M`.
    static func isModelID(_ text: String) -> Bool {
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let repository = parts.first, isRepositoryID(String(repository)) else { return false }
        guard parts.count == 2 else { return true }
        let variant = String(parts[1])
        return matches(variantPattern, variant) && !variant.contains("..")
    }

    /// The name the API reports for model files at `path`: `local/` and the
    /// file's or folder's own name, reduced to the characters a model ID
    /// takes. A name that reduces to nothing becomes `model`.
    static func localAPIName(forPath path: String) -> String {
        var name = PathText.fileName(of: path)
        if name.lowercased().hasSuffix(".gguf") { name.removeLast(5) }

        var reduced = ""
        for character in name {
            let allowed = character.isASCII && (character.isLetter || character.isNumber
                || character == "_" || character == "-" || character == ".")
            let next: Character = allowed ? character : "-"
            // Runs of hyphens and of dots read as separators the ID refuses.
            if let last = reduced.last, last == next, next == "-" || next == "." { continue }
            reduced.append(next)
        }
        let isEdge: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        while let first = reduced.first, !isEdge(first) { reduced.removeFirst() }
        while let last = reduced.last, !isEdge(last) { reduced.removeLast() }
        if reduced.hasSuffix(".git") { reduced.removeLast(4) }
        if reduced.count > 95 { reduced = String(reduced.prefix(95)) }
        while let last = reduced.last, !isEdge(last) { reduced.removeLast() }
        if reduced.isEmpty { reduced = "model" }
        return "local/" + reduced
    }

    /// Whether the file starts with the GGUF magic number.
    static func hasGGUFMagic(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4) else { return false }
        return header == Data("GGUF".utf8)
    }

    enum LocalModelKind: Equatable, Sendable {
        case ggufFile
        case folder
    }

    enum LocalModelIssue: Error, Equatable, Sendable {
        case missing
        case notReadable
        case notGGUF
        case emptyFolder

        var message: String {
            switch self {
            case .missing: return "That file or folder does not exist."
            case .notReadable: return "That file or folder cannot be read."
            case .notGGUF: return "Choose a GGUF file, or the folder of a model."
            case .emptyFolder: return "That folder holds no GGUF file or safetensors checkpoint."
            }
        }

        func launchMessage(at path: String) -> String {
            switch self {
            case .missing: return "model not found at \(path)"
            case .notReadable: return "model not readable at \(path)"
            case .notGGUF: return "model is neither a GGUF file nor a folder at \(path)"
            case .emptyFolder: return "model folder holds no GGUF file or safetensors checkpoint at \(path)"
            }
        }
    }

    /// What the files at `path` are, or why they cannot be served.
    static func inspectLocalModel(atPath path: String) -> Result<LocalModelKind, LocalModelIssue> {
        let resolved = PathText.expandingTilde(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory) else {
            return .failure(.missing)
        }
        guard FileManager.default.isReadableFile(atPath: resolved) else {
            return .failure(.notReadable)
        }
        if isDirectory.boolValue {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: resolved)) ?? []
            let holdsModel = names.contains {
                let lowercased = $0.lowercased()
                return lowercased.hasSuffix(".gguf") || lowercased.hasSuffix(".safetensors")
            }
            return holdsModel ? .success(.folder) : .failure(.emptyFolder)
        }
        return hasGGUFMagic(atPath: resolved) ? .success(.ggufFile) : .failure(.notGGUF)
    }
}
