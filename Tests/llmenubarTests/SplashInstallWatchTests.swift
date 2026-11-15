// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest
@testable import llmenubar

final class SplashInstallWatchTests: XCTestCase {
    private let brew = SplashInstall(path: "/opt/homebrew/bin/splash", kind: .homebrew, version: "1.6.1")
    private let app = SplashInstall(path: "/Applications/Splash.app", kind: .desktopApp, version: "1.6.0")

    func testNothingChangedNeedsNoLookup() {
        XCTAssertFalse(SplashInstall.needsVersionLookup(
            known: [brew, app], paths: [brew.path, app.path], unreadableRetriesUsed: 0
        ))
        XCTAssertFalse(SplashInstall.needsVersionLookup(known: [], paths: [], unreadableRetriesUsed: 0))
    }

    func testAnInstallThatAppearedOrWentIsLookedUp() {
        XCTAssertTrue(SplashInstall.needsVersionLookup(known: [], paths: [brew.path], unreadableRetriesUsed: 0))
        XCTAssertTrue(SplashInstall.needsVersionLookup(known: [brew, app], paths: [brew.path], unreadableRetriesUsed: 0))
        XCTAssertTrue(SplashInstall.needsVersionLookup(known: [brew], paths: [app.path, brew.path], unreadableRetriesUsed: 5))
    }

    func testAnUnreadableVersionIsAskedAgainAFewTimesOnly() {
        let unread = SplashInstall(path: app.path, kind: .desktopApp, version: nil)
        for used in 0..<SplashInstall.unreadableVersionRetries {
            XCTAssertTrue(SplashInstall.needsVersionLookup(known: [unread], paths: [app.path], unreadableRetriesUsed: used))
        }
        XCTAssertFalse(SplashInstall.needsVersionLookup(
            known: [unread], paths: [app.path], unreadableRetriesUsed: SplashInstall.unreadableVersionRetries
        ))
    }
}
