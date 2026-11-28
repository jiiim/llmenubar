// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest
@testable import llmenubar

final class TypedNumbersTests: XCTestCase {
    private let dot = Locale(identifier: "en_US")
    private let comma = Locale(identifier: "de_DE")
    private let spaced = Locale(identifier: "fr_FR")
    private let swiss = Locale(identifier: "de_CH")

    private func check(_ cases: [(String, String)], fraction: Bool, locale: Locale,
                       file: StaticString = #filePath, line: UInt = #line) {
        for (typed, expected) in cases {
            let read = TypedNumbers.read(typed, takesFraction: { _ in fraction }, locale: locale)
            XCTAssertEqual(read, expected, "\(typed)", file: file, line: line)
            let again = TypedNumbers.read(read, takesFraction: { _ in fraction }, locale: locale)
            XCTAssertEqual(again, read, "reading \(typed) twice", file: file, line: line)
        }
    }

    func testWhereTheCommaGroupsAWholeNumberDropsEveryOne() {
        check([("5,000", "5000"), ("1,010,000", "1010000"), ("1,00,000", "100000"), ("50,00", "5000"),
               ("1,000,", "1000"), ("1,2,3", "123"), ("5,,", "5"), (",5", "5"), ("28,5", "285"),
               ("5.", "5"), ("1,000.", "1000"), ("1.000.000", "1000000"),
               ("5 000", "5000"), ("5'000", "5000"), ("-1", "-1"), ("+5", "+5"),
               // The decimal point keeps its meaning, for validation to refuse.
               ("5.0", "5.0"), ("1,000.5", "1000.5")],
              fraction: false, locale: dot)
    }

    func testWhereTheCommaGroupsAFractionReadsALoneMisplacedOneAsThePoint() {
        check([(".5", "0.5"), ("0.5", "0.5"), ("0,5", "0.5"), (",5", "0.5"), ("1,5", "1.5"), ("2,5G", "2.5G"),
               ("1.125", "1.125"), ("5,000", "5000"), ("0,125", "0.125"), ("-1,5", "-1.5"), ("10 s", "10s"),
               ("5,", "5"), ("1,000,", "1000"), ("1,2,3", "123"), ("1,2.5", "12.5"),
               ("1,234.5", "1234.5"), ("1.234,5", "1234.5"), ("1,00,000.5", "100000.5")],
              fraction: true, locale: dot)
    }

    func testWhereTheDotGroupsItIsDroppedWhereItGroups() {
        for fraction in [false, true] {
            check([("5.000", "5000"), ("5.000.", "5000"), ("1.010.000", "1010000"), ("5.", "5"),
                   ("5,0", "5.0"), ("5.0", "5.0"), ("50,00", "50.00"), ("28,5", "28.5"),
                   ("1.234,5", "1234.5"), ("1,234.5", "1234.5")],
                  fraction: fraction, locale: comma)
        }
        check([("0,5", "0.5"), ("0.5", "0.5"), (",5", "0.5"), ("2,5G", "2.5G"),
               ("1,125", "1.1250"), ("5,000", "5.0000")],
              fraction: true, locale: comma)
    }

    func testWhereASpaceGroupsBothSeparatorsMarkAFraction() {
        check([("1.125G", "1.125G"), ("1,125G", "1.125G"), ("0,5", "0.5"), ("0.5", "0.5"), ("5,000", "5.000"),
               ("5.000", "5.000"), ("5.", "5"), ("5,", "5"), ("1 000,5", "1000.5"), ("1\u{202F}000", "1000"),
               ("1.234,5", "1234.5"), ("1.000.000", "1000000")],
              fraction: true, locale: spaced)
        check([("5 000", "5000"), ("5.000", "5.000"), ("5,0", "5.0"), ("5..", "5..")],
              fraction: false, locale: spaced)
        var draft = ServerConfiguration.Config()
        draft.maxMemory = "1.125G"
        let read = draft.readingTypedNumbers(since: ServerConfiguration.Config(), locale: spaced)
        XCTAssertEqual(read.maxMemory, "1.125G")
    }

    func testWhereAnApostropheGroupsACommaIsOnlyForReadingAWholeNumber() {
        check([("1,125G", "1.125G"), ("5,000", "5.000"), ("5.000", "5.000"), ("0,5", "0.5"),
               ("5\u{2019}000", "5000"), ("5'000.5", "5000.5"), ("1,234.5", "1234.5"), ("5,", "5")],
              fraction: true, locale: swiss)
        check([("5,000", "5000"), ("50,00", "5000"), ("5\u{2019}000", "5000"), ("5.0", "5.0")],
              fraction: false, locale: swiss)
    }

    @MainActor
    func testEverySpellingOfNoCacheTurnsItOff() {
        let suite = "llmenubar.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let editor = SettingsEditor(
            server: ServerManager(config: ServerConfiguration(defaults: defaults, secrets: MemorySecretStore())))
        for (size, off) in [("0", true), ("00", true), ("0G", true), (" 0 GB", true), ("", false), ("auto", false), ("16G", false)] {
            editor.draft.maxCacheDisk = size
            XCTAssertEqual(editor.draftTurnsCacheOff, off, size)
        }
    }

    func testWhatIsNotANumberOrIsMalformedIsLeftAlone() {
        let either = ["", "auto", "off", "1e3", "1_000", "1.2.3", "0.0.0", "--5", "five", "5G2", ","]
        for fraction in [false, true] {
            for locale in [dot, comma] {
                check(either.map { ($0, $0) }, fraction: fraction, locale: locale)
            }
            // Where the dot groups, stray ones at the end are forgiven, as
            // stray commas are where the comma groups.
            check([("5..", "5"), ("5...", "5")], fraction: fraction, locale: comma)
            check(["5..", "5..."].map { ($0, $0) }, fraction: fraction, locale: dot)
            check(["1,2,3", "1,000,", "1.234,5,6", "1,234.5.6", "1.5,234", "1.2.3,4"].map { ($0, $0) },
                  fraction: fraction, locale: comma)
        }
        check(["1.234,5,6", "1,234.5.6", "1.5,234", "1.2.3,4"].map { ($0, $0) }, fraction: true, locale: dot)
    }

    func testTheKindOfFieldDecidesWhatACommaMeans() {
        let saved = ServerConfiguration.Config()
        var draft = saved
        draft.shutdownTimeout = "1,0"
        draft.maxMemory = "28,5"
        draft.pleMemory = "2,5G"
        draft.decodeShare = "0,5"
        let read = draft.readingTypedNumbers(since: saved, locale: dot)
        XCTAssertEqual(read.shutdownTimeout, "10")
        XCTAssertEqual(read.maxMemory, "285", "bytes take no fraction")
        XCTAssertEqual(read.pleMemory, "2.5G")
        XCTAssertEqual(read.decodeShare, "0.5")
    }

    func testADecimalPointInAWholeNumberIsRefused() {
        let saved = ServerConfiguration.Config()
        for (locale, typed) in [(dot, ["0.5", "1.5", "5.0"]), (comma, ["0.5", "0,5", "5.0", "5,0", "0,0"])] {
            for text in typed {
                var draft = saved
                draft.shutdownTimeout = text
                let candidate = draft.readingTypedNumbers(since: saved, locale: locale).normalized()
                XCTAssertNotNil(candidate.validationErrors()[.shutdownTimeout], "\(text) in \(locale.identifier)")
            }
        }
    }

    func testOnlyWhatWasTypedSinceTheSaveIsRead() {
        var saved = ServerConfiguration.Config()
        saved.decodeShare = "1.125"
        var draft = saved
        draft.maxContext = "128,000"
        draft.maxMemory = "28 G"
        draft.maxCacheDisk = "0G"
        draft.maxCacheDiskWrites = "00,0 GiB"
        draft.shutdownTimeout = "00"
        draft.servedModelNames = "a,b"
        let read = draft.readingTypedNumbers(since: saved, locale: comma).normalized()
        XCTAssertEqual(read.decodeShare, "1.125", "unchanged")
        XCTAssertEqual(read.maxMemory, "28G")
        XCTAssertEqual(read.maxCacheDisk, "0")
        XCTAssertEqual(read.maxCacheDiskWrites, "0")
        XCTAssertEqual(read.shutdownTimeout, "0")
        XCTAssertEqual(read.servedModelNames, "a,b", "a list keeps its commas")
        let english = draft.readingTypedNumbers(since: saved, locale: dot).normalized()
        XCTAssertEqual(english.maxContext, "128000")
        XCTAssertEqual(english.shutdownTimeout, "0")
    }

    func testMalformedZeroSizesAreNotRewrittenToZero() {
        let saved = ServerConfiguration.Config()
        for bad in ["0.0.0G", "0..G"] {
            var draft = saved
            draft.maxCacheDisk = bad
            draft.maxCacheDiskWrites = bad
            let candidate = draft.readingTypedNumbers(since: saved, locale: dot).normalized()
            XCTAssertEqual(candidate.maxCacheDisk, bad)
            XCTAssertEqual(candidate.maxCacheDiskWrites, bad)
            XCTAssertNotNil(candidate.validationErrors()[.maxCacheDisk], bad)
            XCTAssertNotNil(candidate.validationErrors()[.maxCacheDiskWrites], bad)
        }
    }

    @MainActor
    func testSettingsJudgesAndSavesTheNumberAsRead() {
        let config = ServerConfiguration.Config()
        var draft = config
        draft.queueSize = "1,000"
        XCTAssertNotNil(draft.validationErrors()[.queueSize])
        XCTAssertNil(draft.readingTypedNumbers(since: config, locale: dot).validationErrors()[.queueSize])
    }

    @MainActor
    func testFormattedEquivalentNumberDoesNotCountAsAChange() {
        let suite = "llmenubar.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = ServerManager(config: ServerConfiguration(defaults: defaults, secrets: MemorySecretStore()))
        var initial = server.configurationSnapshot()
        initial.maxMemory = "28G"
        initial.maxCacheDisk = "0"
        server.config.replace(with: initial)

        let editor = SettingsEditor(server: server)
        editor.draft.maxMemory = "28 G"
        editor.draft.maxCacheDisk = "0G"
        XCTAssertEqual(editor.candidate(from: editor.draft), server.configurationSnapshot())
    }
}
