// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest

@testable import llmenubar

final class ListenAddressTests: XCTestCase {
    func testClassification() {
        XCTAssertEqual(ListenAddress("127.0.0.1").kind, .ipv4)
        XCTAssertEqual(ListenAddress("192.168.1.20").kind, .ipv4)
        XCTAssertEqual(ListenAddress("0.0.0.0").kind, .unspecifiedIPv4)
        XCTAssertEqual(ListenAddress("::1").kind, .ipv6)
        XCTAssertEqual(ListenAddress("fe80::1").kind, .ipv6)
        XCTAssertEqual(ListenAddress("localhost").kind, .name)
        XCTAssertEqual(ListenAddress("mymac.local").kind, .name)
        XCTAssertEqual(ListenAddress("").kind, .name)
    }

    func testEverySpellingOfTheIPv6WildcardIsUnspecified() {
        for host in ["::", "[::]", "::0", "[::0]", "0:0:0:0:0:0:0:0", "[0:0:0:0:0:0:0:0]", "::ffff:0.0.0.0"] {
            XCTAssertEqual(ListenAddress(host).kind, .unspecifiedIPv6, host)
            XCTAssertTrue(ListenAddress(host).isUnspecified, host)
        }
        XCTAssertFalse(ListenAddress("::ffff:10.0.0.1").isUnspecified)
    }

    func testReachableHostsForUnspecifiedAddressesAreLoopback() {
        XCTAssertEqual(ListenAddress("0.0.0.0").reachableURLHost, "127.0.0.1")
        XCTAssertEqual(ListenAddress("0.0.0.0").reachableSocketHost, "127.0.0.1")
        XCTAssertEqual(ListenAddress("::").reachableURLHost, "[::1]")
        XCTAssertEqual(ListenAddress("[::]").reachableSocketHost, "::1")
    }

    func testOtherHostsAreReachedAsConfigured() {
        XCTAssertEqual(ListenAddress("192.168.1.20").reachableURLHost, "192.168.1.20")
        XCTAssertEqual(ListenAddress("mymac.local").reachableURLHost, "mymac.local")
        XCTAssertEqual(ListenAddress("::1").reachableURLHost, "[::1]")
        XCTAssertEqual(ListenAddress("[::1]").reachableURLHost, "[::1]")
        XCTAssertEqual(ListenAddress("[::1]").reachableSocketHost, "::1")
        XCTAssertEqual(ListenAddress("  127.0.0.1 ").reachableURLHost, "127.0.0.1")
    }

    func testBareFormHasNoBrackets() {
        XCTAssertEqual(ListenAddress("[::1]").bare, "::1")
        XCTAssertEqual(ListenAddress("::1").bare, "::1")
        XCTAssertEqual(ListenAddress("[]").bare, "[]")
        XCTAssertEqual(ListenAddress("127.0.0.1").bare, "127.0.0.1")
    }

    func testDisplayKeepsTheConfiguredAddressAndBracketsIPv6() {
        XCTAssertEqual(ListenAddress("0.0.0.0").displayed(port: 8000), "0.0.0.0:8000")
        XCTAssertEqual(ListenAddress("::").displayed(port: 8000), "[::]:8000")
        XCTAssertEqual(ListenAddress("[::1]").displayed(port: 9), "[::1]:9")
        XCTAssertEqual(ListenAddress("localhost").displayed(port: 8000), "localhost:8000")
    }

    func testURLsAreBuiltForEveryKindOfHost() {
        XCTAssertEqual(ListenAddress("0.0.0.0").url(port: 8123, path: "/ready")?.absoluteString,
                       "http://127.0.0.1:8123/ready")
        XCTAssertEqual(ListenAddress("::").url(port: 8123, path: "/health")?.absoluteString,
                       "http://[::1]:8123/health")
        XCTAssertEqual(ListenAddress("[0:0:0:0:0:0:0:0]").url(port: 8123, path: "/health")?.absoluteString,
                       "http://[::1]:8123/health")
        XCTAssertEqual(ListenAddress("fe80::1").url(port: 8, path: "/x")?.absoluteString,
                       "http://[fe80::1]:8/x")
        XCTAssertEqual(ListenAddress("mymac.local").url(port: 8000, path: "/ready")?.absoluteString,
                       "http://mymac.local:8000/ready")
    }

    /// Foundation traps on host text it cannot hold, so these must come back nil.
    func testTextThatIsNotAHostGivesNoURLInsteadOfTrapping() {
        for text in ["foo/bar", "localhost:8000", "fe80::1%en0", "[]", "a?b", "a#b", "a@b",
                     "-bad.example", "bad-.example", "a..b", "ünï.example", "http://host"] {
            XCTAssertNil(ListenAddress(text).url(port: 8000, path: "/"), text)
            XCTAssertFalse(ListenAddress(text).isWellFormed, text)
        }
    }

    func testValidHostsStillGiveURLs() {
        for text in ["127.0.0.1", "0.0.0.0", "localhost", "my-mac.local", "my-mac.local.", "::1", "[::1]"] {
            XCTAssertNotNil(ListenAddress(text).url(port: 8000, path: "/"), text)
        }
    }

    func testLoopbackIsOnlyThisMac() {
        for host in ["127.0.0.1", "127.9.9.9", "localhost", "LOCALHOST", "::1", "[::1]"] {
            XCTAssertTrue(ListenAddress(host).isLoopback, host)
        }
        for host in ["0.0.0.0", "192.168.1.5", "mymac.local", "::"] {
            XCTAssertFalse(ListenAddress(host).isLoopback, host)
        }
    }
}
