// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest

@testable import llmenubar

final class OtherDeviceEndpointsTests: XCTestCase {
    private let names = LocalNetworkNames(hostName: "Jims-Mac.local", ipv4: "192.168.1.20")

    func testAnAllNetworksServerIsReachedByTheMacsNames() {
        let entries = OtherDeviceEndpoints.entries(host: "0.0.0.0", port: 8000, names: names)
        XCTAssertEqual(entries.map(\.label), ["Jims-Mac.local", "192.168.1.20"])
        XCTAssertEqual(entries[0].openAI?.absoluteString, "http://Jims-Mac.local:8000/v1")
        XCTAssertEqual(entries[1].anthropic?.absoluteString, "http://192.168.1.20:8000")
    }

    func testAServerOnOneAddressNeedsNoOtherNames() {
        XCTAssertEqual(OtherDeviceEndpoints.entries(host: "127.0.0.1", port: 8000, names: names), [])
        XCTAssertEqual(OtherDeviceEndpoints.entries(host: "192.168.1.5", port: 8000, names: names), [])
    }

    func testMissingNamesAreLeftOut() {
        let entries = OtherDeviceEndpoints.entries(
            host: "0.0.0.0", port: 9, names: LocalNetworkNames(hostName: nil, ipv4: "10.0.0.2"))
        XCTAssertEqual(entries.map(\.label), ["10.0.0.2"])
    }

    func testTheRealNamesHaveTheExpectedShape() {
        let current = LocalNetworkNames.current()
        if let host = current.hostName { XCTAssertTrue(host.hasSuffix(".local"), host) }
        if let ip = current.ipv4 {
            var address = in_addr()
            XCTAssertEqual(inet_pton(AF_INET, ip, &address), 1, ip)
            XCTAssertFalse(ip.hasPrefix("127.") || ip.hasPrefix("169.254."))
        }
    }
}
