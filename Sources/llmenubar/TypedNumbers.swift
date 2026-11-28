// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation

/// Reads a number as a person types it into the form Splash takes: ASCII
/// digits with `.` before any fraction.
///
/// The separator that only groups digits in the locale is forgiven where it is
/// misplaced; the other keeps its meaning. Where the dot marks fractions, a
/// comma is for reading: a whole number drops every one, and a value that takes
/// a fraction reads a lone one that groups nothing, as in `0,5`, as a decimal
/// point. Where the locale groups with a dot, as in Germany, it is
/// dropped where it does group, and elsewhere stays the decimal point the app
/// itself writes. Where the comma marks fractions and a space groups, as in
/// France, both mark a fraction. One separator before exactly three digits, as
/// in `5,000`, groups only if it is the locale's grouping dot or comma. Spaces
/// and apostrophes, which also group digits, are dropped. Malformed text
/// and text that is not a number with an optional unit are left as they are.
enum TypedNumbers {
    static func read(_ text: String, takesFraction: (_ unit: String) -> Bool, locale: Locale) -> String {
        let compact = String(text.filter { !$0.isWhitespace && $0 != "'" && $0 != "’" })
        let sign = compact.prefix { $0 == "-" || $0 == "+" }
        let number = compact.dropFirst(sign.count).prefix { isDigit($0) || isSeparator($0) }
        let unit = compact.dropFirst(sign.count + number.count)
        guard sign.count <= 1, number.contains(where: isDigit), unit.allSatisfy(\.isLetter) else { return text }
        let marks = Marks(locale)
        let forgiven = forgivingGrouping(String(number), fraction: takesFraction(String(unit)), marks: marks)
        // What cannot be read keeps the text as typed.
        guard let read = plain(forgiven, marks: marks) else { return text }
        return sign + read + unit
    }

    /// What `,` and `.` do in a locale.
    private struct Marks {
        let commaMarksFractions: Bool
        let commaGroups: Bool
        let dotGroups: Bool

        init(_ locale: Locale) {
            commaMarksFractions = locale.decimalSeparator == ","
            // Switzerland, for one, marks fractions with a dot and groups with
            // an apostrophe, so neither of these follows from the other.
            commaGroups = !commaMarksFractions && locale.groupingSeparator == ","
            dotGroups = commaMarksFractions && locale.groupingSeparator == "."
        }

        func groups(_ separator: Character) -> Bool {
            separator == "," ? commaGroups : dotGroups
        }
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character == "," || character == "."
    }

    private static func hasAdjacentSeparators(_ number: String) -> Bool {
        var previousWasSeparator = false
        for character in number {
            let separator = isSeparator(character)
            if separator && previousWasSeparator { return true }
            previousWasSeparator = separator
        }
        return false
    }

    /// `number` without the grouping separators that can be ignored wherever
    /// they sit.
    private static func forgivingGrouping(_ number: String, fraction: Bool, marks: Marks) -> String {
        var number = number
        if marks.commaMarksFractions {
            while marks.dotGroups, number.last == "." { number.removeLast() }
            return number
        }
        if !fraction { return number.filter { $0 != "," } }
        while number.last == "," { number.removeLast() }
        // Before a decimal point, or repeated with none, commas only group.
        if let last = number.last(where: isSeparator),
           last == "." || (!number.contains(".") && number.filter({ $0 == "," }).count > 1) {
            number.removeAll { $0 == "," }
        }
        return number
    }

    /// The number in its plain form, or nil when it cannot be read.
    private static func plain(_ number: String, marks: Marks) -> String? {
        guard !hasAdjacentSeparators(number) else { return nil }
        var number = number
        if let trailing = number.last, isSeparator(trailing) {
            let head = number.dropLast()
            guard !head.contains(trailing) else { return nil }
            number = String(head)
        }
        let separators = number.filter(isSeparator)
        guard let last = separators.last else { return number }

        let point: Character?
        if Set(separators).count == 2 {
            // `1,234.5` or `1.234,5`: the last separator marks the fraction
            // and the other must group the digits before it.
            let parts = number.split(separator: last, omittingEmptySubsequences: false)
            let grouping: Character = last == "." ? "," : "."
            guard parts.count == 2,
                  isGrouping(String(parts[0]), by: grouping),
                  parts[1].allSatisfy(isDigit)
            else { return nil }
            point = last
        } else if separators.count > 1 {
            guard isGrouping(number, by: last) else { return nil }
            point = nil
        } else {
            point = marks.groups(last) && isGrouped(number, by: last) ? nil : last
        }

        var result = ""
        for character in number {
            if isDigit(character) { result.append(character) }
            else if character == point { result.append(".") }
        }
        if result.hasPrefix(".") { result = "0" + result }
        // Written back, `1.125` would read as a thousand where the dot groups,
        // so give it a fourth decimal there.
        if marks.dotGroups, isGrouped(result, by: ".") { result += "0" }
        return result
    }

    /// `5,000` or `1,234,567`: one to three digits, not starting with zero, then
    /// groups of three.
    private static func isGrouped(_ number: String, by separator: Character) -> Bool {
        let parts = number.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count > 1, let first = parts.first,
              (1...3).contains(first.count), first.first != "0",
              parts.allSatisfy({ $0.allSatisfy(isDigit) })
        else { return false }
        return parts.dropFirst().allSatisfy { $0.count == 3 }
    }

    /// Standard three-digit grouping, or Indian grouping with commas
    /// (`1,00,000`).
    private static func isGrouping(_ number: String, by separator: Character) -> Bool {
        if isGrouped(number, by: separator) { return true }
        guard separator == "," else { return false }
        let parts = number.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count >= 3, let first = parts.first, let last = parts.last,
              (1...2).contains(first.count), first.first != "0",
              last.count == 3,
              parts.allSatisfy({ $0.allSatisfy(isDigit) })
        else { return false }
        return parts.dropFirst().dropLast().allSatisfy { $0.count == 2 }
    }
}

extension ServerConfiguration.Config {
    /// This draft with the numbers typed since `saved` read into the form
    /// Splash takes. A value left as it was saved is not read again.
    func readingTypedNumbers(since saved: Self, locale: Locale = .current) -> Self {
        typealias Field = WritableKeyPath<Self, String>
        var config = self
        func read(_ fields: [Field], takesFraction: (String) -> Bool) {
            for field in fields where self[keyPath: field] != saved[keyPath: field] {
                config[keyPath: field] = TypedNumbers.read(
                    self[keyPath: field], takesFraction: takesFraction, locale: locale
                )
            }
        }
        // Sizes take a fraction with a unit only, as in `2.5G`.
        let sizes: [Field] = [\.maxMemory, \.pleMemory, \.expertMemory, \.sparseKVMemory,
                              \.maxCacheDisk, \.maxCacheDiskWrites, \.maxRequestSize]
        read(sizes) { !$0.isEmpty }
        read([\.maxContext, \.thinkingTokenBudget, \.maxImagePixels, \.shutdownTimeout, \.queueSize,
              \.maxConcurrentRequests, \.samplingTopK]) { _ in false }
        read([\.idleRelease, \.requestTimeout, \.decodeShare, \.samplingTemperature, \.samplingTopP,
              \.samplingMinP, \.samplingPresencePenalty, \.samplingFrequencyPenalty,
              \.samplingRepetitionPenalty]) { _ in true }
        // No SSD cache, or no write limit, is `0` whatever unit follows it.
        for field in [\Self.maxCacheDisk, \Self.maxCacheDiskWrites]
        where self[keyPath: field] != saved[keyPath: field] {
            let value = config[keyPath: field]
            let zeros = value.prefix { $0 == "0" || $0 == "." }
            let unit = value.dropFirst(zeros.count).uppercased()
            if zeros.contains("0"), zeros.filter({ $0 == "." }).count <= 1,
               ["K", "KB", "KIB", "M", "MB", "MIB", "G", "GB", "GIB"].contains(unit) {
                config[keyPath: field] = "0"
            }
        }
        return config
    }
}
