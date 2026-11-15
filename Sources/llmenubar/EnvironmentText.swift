// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation

/// The extra environment variables for Splash, written one `NAME=VALUE` to a
/// line, such as `SPLASH_CRASH_TRACE=1`. The value is everything after the
/// first `=`, taken literally: there is no quoting to get wrong.
enum EnvironmentText {
    struct Assignment: Equatable {
        let name: String
        let value: String
    }

    /// The variable `apiKey` is passed in. It has a setting of its own, so a
    /// line naming it would be a second, silent way to set the same thing.
    static let reservedName = "SPLASH_API_KEY"

    /// Words that mark a variable's value as a secret. Matched anywhere in the
    /// name, so `HF_TOKEN`, `HUGGING_FACE_HUB_TOKEN` and the next service's
    /// `..._API_KEY` are all covered. Values of other variables, such as
    /// `SPLASH_CRASH_TRACE=1`, stay visible: a bug report needs them.
    private static let secretWords = ["TOKEN", "SECRET", "KEY", "PASSWORD", "PASSWD", "CREDENTIAL", "AUTH"]

    /// Whether the value of `name` must stay out of the log, the command
    /// preview and anything else that gets pasted around.
    static func isSecret(_ name: String) -> Bool {
        if name == reservedName { return true }
        let upper = name.uppercased()
        return secretWords.contains { upper.contains($0) }
    }

    static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              first == "_" || (first.isASCII && CharacterSet.letters.contains(first))
        else { return false }
        return name.unicodeScalars.allSatisfy {
            $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0))
        }
    }

    /// The assignments the lines hold, in order. A line that is blank or starts
    /// with `#` holds none; a line that is not an assignment is skipped here
    /// and reported by `firstError`.
    static func parse(_ text: String) -> [Assignment] {
        lines(in: text).compactMap { line in
            guard case .success(let assignment) = assignment(from: line) else { return nil }
            return assignment
        }
    }

    /// The message for the first line that is not an assignment, naming it.
    static func firstError(in text: String) -> String? {
        for line in lines(in: text) {
            if case .failure(let error) = assignment(from: line) { return error.message }
        }
        return nil
    }

    private struct LineError: Error {
        let message: String
    }

    private static func lines(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private static func assignment(from line: String) -> Result<Assignment, LineError> {
        guard let equals = line.firstIndex(of: "=") else {
            return .failure(LineError(message: "“\(line)” is not NAME=VALUE."))
        }
        let name = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        guard isValidName(name) else {
            return .failure(LineError(message: "“\(name)” is not a variable name: use letters, digits and underscores."))
        }
        guard name != reservedName else {
            return .failure(LineError(message: "Set the key in the API key field on the Server pane."))
        }
        return .success(Assignment(name: name, value: value))
    }
}
