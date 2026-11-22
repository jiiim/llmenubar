// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation

/// The value rules of `splash serve`'s options. A field that breaks one is
/// marked in Settings, where the alternative is a launch that fails with the
/// same complaint a moment later.
///
/// Every option here is optional: a blank field leaves the option off the
/// command line and Splash chooses.
enum SplashOptionValues {
    /// The words Splash takes for "choose for me" in the options that have it.
    static func isAuto(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).lowercased() == "auto"
    }

    // MARK: Sizes

    private static let sizeUnits: [(suffix: String, multiplier: Decimal)] = {
        var units: [(suffix: String, multiplier: Decimal)] = []
        var multiplier: Decimal = 1
        for letter in ["K", "M", "G"] {
            multiplier *= 1_024
            for suffix in ["IB", "B", ""] {
                units.append((letter + suffix, multiplier))
            }
        }
        return units
    }()

    private static let maximumSize = Decimal(Int64.max)

    /// A byte count Splash accepts: whole bytes, or a number with a K, M or G
    /// unit (`28G`, `2.5GB`, `512MiB`, 1024-based). At least one byte.
    static func byteCount(_ text: String) -> Decimal? {
        var normalized = text.trimmingCharacters(in: .whitespaces).uppercased()
        var multiplier: Decimal = 1
        var hasUnit = false
        // Longest suffix first, so `GIB` is not read as `B` after `GI`.
        for unit in sizeUnits.filter({ !$0.suffix.isEmpty }).sorted(by: { $0.suffix.count > $1.suffix.count }) {
            if normalized.hasSuffix(unit.suffix) {
                normalized.removeLast(unit.suffix.count)
                multiplier = unit.multiplier
                hasUnit = true
                break
            }
        }
        guard isPlainNumber(normalized, allowingFraction: hasUnit),
              let number = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }
        let bytes = number * multiplier
        var rounded = Decimal()
        var source = bytes
        NSDecimalRound(&rounded, &source, 0, .down)
        guard rounded >= 1, rounded <= maximumSize else { return nil }
        return rounded
    }

    private static func isPlainNumber(_ text: String, allowingFraction: Bool) -> Bool {
        guard !text.isEmpty else { return false }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= (allowingFraction ? 2 : 1) else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    // MARK: Durations

    /// Seconds in a duration written as seconds, or with an `s`, `m` or `h`
    /// unit. Positive and finite.
    static func seconds(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let last = trimmed.last else { return nil }
        let units: [Character: Double] = ["s": 1, "m": 60, "h": 3_600]
        let multiplier = units[last]
        let numeric = multiplier == nil ? trimmed : String(trimmed.dropLast())
        guard isPlainNumber(numeric, allowingFraction: true),
              let value = Double(numeric)
        else { return nil }
        let result = value * (multiplier ?? 1)
        return result.isFinite && result > 0 ? result : nil
    }

    // MARK: Tokens

    static let maximumContextTokens = 1_010_000

    /// A token count, optionally with `K` (1024) or `M` (1,000,000).
    static func contextTokens(_ text: String) -> Int? {
        var normalized = text.trimmingCharacters(in: .whitespaces).uppercased()
        var multiplier = 1
        if normalized.hasSuffix("K") {
            normalized.removeLast()
            multiplier = 1_024
        } else if normalized.hasSuffix("M") {
            normalized.removeLast()
            multiplier = 1_000_000
        }
        guard !normalized.isEmpty, normalized.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(normalized)
        else { return nil }
        let (tokens, overflow) = value.multipliedReportingOverflow(by: multiplier)
        guard !overflow, (1...maximumContextTokens).contains(tokens) else { return nil }
        return tokens
    }

    // MARK: Whole numbers and decimals

    static func wholeNumber(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(trimmed)
    }

    static func nonnegativeDecimal(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard isPlainNumber(trimmed, allowingFraction: true),
              let value = Double(trimmed), value.isFinite
        else { return nil }
        return value
    }

    static let imagePixelRange = 65_536...4_194_304

    static let concurrentRequestRange = 1...8

    // MARK: Sampling defaults

    /// What `--sampling-default NAME=VALUE` takes for one name, as Splash
    /// checks it. Its bounds are 32-bit floats: a value is in range when it
    /// lies between the smallest and the largest a 32-bit float can hold.
    enum SamplingRule {
        case closed(Double, Double)
        /// Above zero: from a 32-bit float's smallest step from zero up to the bound.
        case aboveZero(upTo: Double)
        /// A whole number, `-1` or more.
        case wholeNumber

        private static let smallest = Double(Float.leastNonzeroMagnitude)

        func accepts(_ text: String) -> Bool {
            if case .wholeNumber = self { return SplashOptionValues.pythonInteger(text).map { $0 >= -1 } ?? false }
            guard let value = SplashOptionValues.pythonFloat(text) else { return false }
            switch self {
            case .closed(let low, let high): return (low...high).contains(value)
            case .aboveZero(let high): return (Self.smallest...high).contains(value)
            case .wholeNumber: return false
            }
        }

        /// What the value is, for a note and a message: "a number from 0 to 2".
        var requirement: String {
            switch self {
            case .closed(let low, let high): return "a number from \(Self.shown(low)) to \(Self.shown(high))"
            case .aboveZero(let high):
                return "a number above 0 and up to \(high == 1 ? "1" : "3.4028235e38")"
            case .wholeNumber: return "a whole number, -1 or more"
            }
        }

        private static func shown(_ value: Double) -> String {
            value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
        }
    }

    /// The digits of `text` as ASCII with the underscores that may separate
    /// them removed, or nil when a digit is missing or an underscore does not
    /// sit between two. Splash reads values as Python does, which takes any
    /// script's decimal digits.
    private static func asciiDigits(_ text: Substring) -> String? {
        var result = ""
        var previousWasDigit = false
        var pendingUnderscore = false
        for scalar in text.unicodeScalars {
            if scalar == "_" {
                guard previousWasDigit else { return nil }
                pendingUnderscore = true
                previousWasDigit = false
            } else if scalar.properties.generalCategory == .decimalNumber,
                      let value = scalar.properties.numericValue {
                result += String(Int(value))
                previousWasDigit = true
                pendingUnderscore = false
            } else {
                return nil
            }
        }
        return previousWasDigit && !pendingUnderscore ? result : nil
    }

    /// A number written as Python's `float` takes it: an optional sign,
    /// digits with an optional point, and an optional exponent. Nil when it is
    /// not one or is not finite.
    static func pythonFloat(_ text: String) -> Double? {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        var sign = ""
        if let first = rest.first, first == "+" || first == "-" {
            sign = first == "-" ? "-" : ""
            rest = rest.dropFirst()
        }
        var exponent = ""
        if let marker = rest.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            var power = rest[rest.index(after: marker)...]
            var powerSign = ""
            if let first = power.first, first == "+" || first == "-" {
                powerSign = first == "-" ? "-" : ""
                power = power.dropFirst()
            }
            guard let digits = asciiDigits(power) else { return nil }
            exponent = "e" + powerSign + digits
            rest = rest[..<marker]
        }
        let halves = rest.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard halves.count <= 2, !halves.isEmpty else { return nil }
        let whole = halves[0].isEmpty ? "" : asciiDigits(halves[0])
        let fraction = halves.count == 2 && !halves[1].isEmpty ? asciiDigits(halves[1]) : ""
        guard let whole, let fraction, !(whole.isEmpty && fraction.isEmpty) else { return nil }
        guard let value = Double(sign + (whole.isEmpty ? "0" : whole) + "." + (fraction.isEmpty ? "0" : fraction) + exponent),
              value.isFinite
        else { return nil }
        return value
    }

    /// A whole number written as Python's `int` takes it: an optional sign
    /// and digits. Values beyond `Int` saturate, which no bound here tells apart.
    static func pythonInteger(_ text: String) -> Int? {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        var negative = false
        if let first = rest.first, first == "+" || first == "-" {
            negative = first == "-"
            rest = rest.dropFirst()
        }
        guard let digits = asciiDigits(rest) else { return nil }
        guard let magnitude = Int(digits) else { return negative ? Int.min : Int.max }
        return negative ? -magnitude : magnitude
    }

    // MARK: Names and lists

    /// Items of a comma-separated field, trimmed, without empty ones.
    static func items(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// An alias for the served model: no whitespace or URL delimiters, and no
    /// empty or dot-only path parts.
    static func isModelAlias(_ text: String) -> Bool {
        // A value that starts with a dash reaches Splash as the next argument and
        // is read as an option.
        guard !text.isEmpty, !text.hasPrefix("-") else { return false }
        let forbidden = Set("\\%?#")
        guard text.allSatisfy({ !$0.isWhitespace && !forbidden.contains($0) && $0.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f } })
        else { return false }
        return !text.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// `*`, or `scheme://host` with an optional port, as a browser sends it in
    /// an `Origin` header. Splash compares origins exactly and refuses anything
    /// else: a path, query or fragment, user information, a pattern, spaces or
    /// non-ASCII text, an empty host or a port that is not a number.
    static func isOrigin(_ text: String) -> Bool {
        if text == "*" { return true }
        guard text.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }),
              !text.contains("*"),
              let separator = text.range(of: "://")
        else { return false }
        let scheme = text[..<separator.lowerBound]
        let authority = text[separator.upperBound...]
        guard let first = scheme.first, first.isLetter,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+.-".contains($0) }),
              !authority.isEmpty,
              !authority.contains(where: { "/?#@\\".contains($0) })
        else { return false }
        // Host, then an optional :port. An IPv6 host is bracketed.
        var host = Substring(authority)
        var port: Substring?
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return false }
            let rest = host[host.index(after: close)...]
            host = host[host.index(after: host.startIndex)..<close]
            if !rest.isEmpty {
                guard rest.hasPrefix(":") else { return false }
                port = rest.dropFirst()
            }
        } else if let colon = host.lastIndex(of: ":") {
            port = host[host.index(after: colon)...]
            host = host[..<colon]
            if host.contains(":") { return false }
        }
        if let port {
            guard !port.isEmpty, port.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(port), number <= 65_535
            else { return false }
        }
        return !host.isEmpty
    }
}
