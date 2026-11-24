// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import llmenubar

final class SplashEndpointsTests: XCTestCase {
    func testLoopbackAddresses() {
        let endpoints = SplashEndpoints(host: "127.0.0.1", port: 8000)
        XCTAssertEqual(endpoints.chatPage?.absoluteString, "http://127.0.0.1:8000/")
        XCTAssertEqual(endpoints.openAIBase?.absoluteString, "http://127.0.0.1:8000/v1")
        XCTAssertEqual(endpoints.anthropicBase?.absoluteString, "http://127.0.0.1:8000")
    }

    func testAnUnspecifiedAddressIsReachedAtLoopback() {
        let endpoints = SplashEndpoints(host: "0.0.0.0", port: 9001)
        XCTAssertEqual(endpoints.chatPage?.absoluteString, "http://127.0.0.1:9001/")
        let v6 = SplashEndpoints(host: "::", port: 9001)
        XCTAssertEqual(v6.openAIBase?.absoluteString, "http://[::1]:9001/v1")
    }

    func testAHostNameAndAnIPv6Address() {
        XCTAssertEqual(
            SplashEndpoints(host: "mymac.local", port: 80).anthropicBase?.absoluteString,
            "http://mymac.local:80"
        )
        XCTAssertEqual(
            SplashEndpoints(host: "[fe80::1]", port: 8000).chatPage?.absoluteString,
            "http://[fe80::1]:8000/"
        )
    }

    func testNativeContextWindowReadsWithCommas() {
        XCTAssertEqual(NativeContextWindow.tokens, 256 * 1_024)
        XCTAssertEqual(NativeContextWindow.description, "262,144 tokens (256K)")
    }

    func testTheContextNoteNamesTheWindowOfTheModelServed() {
        var config = ServerConfiguration.Config()
        config.huggingFaceModel = "unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M"
        XCTAssertTrue(NativeContextWindow.note(for: config).contains("262,144 tokens (256K)"))
        XCTAssertTrue(NativeContextWindow.note(for: config).contains("YaRN"))

        config.huggingFaceModel = "unsloth/Inkling-2-Mini-GGUF:UD-Q4_K_M"
        let inkling = NativeContextWindow.note(for: config)
        XCTAssertTrue(inkling.contains("1,048,576 tokens (1024K)"), inkling)
        XCTAssertTrue(inkling.contains("1,010,000"), inkling)
        XCTAssertFalse(inkling.contains("262,144"), inkling)
        XCTAssertFalse(inkling.contains("YaRN"), inkling)

        config.modelSource = .local
        config.modelPath = "/models/Inkling-2-Mini-UD-Q8_K_XL.gguf"
        XCTAssertTrue(NativeContextWindow.note(for: config).contains("1,048,576"))
    }

    func testTheLogDefaultsToTenMegabytes() {
        XCTAssertEqual(ServerConfiguration.Config().logMaxSizeMB, 10)
    }

    // MARK: Menu line

    func testTheAddressOpensOnlyWhileRunningWithTheChatPageOn() {
        XCTAssertTrue(SplashEndpoints.opensChatPage(status: .running(pid: 1), chatPageEnabled: true))
        XCTAssertFalse(SplashEndpoints.opensChatPage(status: .running(pid: 1), chatPageEnabled: false))
        for status in [ServerStatus.stopped, .starting, .restarting, .stopping, .error("x")] {
            XCTAssertFalse(SplashEndpoints.opensChatPage(status: status, chatPageEnabled: true))
        }
    }

    // MARK: API Information submenu

    func testTheAPISubmenuOffersBothBaseURLsAndTheKey() {
        var config = ServerConfiguration.Config()
        config.host = "127.0.0.1"
        config.port = 8000
        config.apiKey = "llm-secret"
        let menu = APIInformationMenu(config)
        XCTAssertEqual(menu.anthropic?.absoluteString, "http://127.0.0.1:8000")
        XCTAssertEqual(menu.openAI?.absoluteString, "http://127.0.0.1:8000/v1")
        XCTAssertEqual(menu.keyTitle, "Copy API Key")
        XCTAssertTrue(menu.keyIsAvailable)
    }

    func testWithNoKeyTheItemSaysSoAndIsUnavailable() {
        var config = ServerConfiguration.Config()
        config.apiKey = ""
        XCTAssertEqual(APIInformationMenu(config).keyTitle, "Copy API Key (not set)")
        XCTAssertFalse(APIInformationMenu(config).keyIsAvailable)
        config.apiKey = "   "
        XCTAssertFalse(APIInformationMenu(config).keyIsAvailable, "blanks are no key")
    }

    func testTheAddressesFollowTheConfiguredHostAndPort() {
        var config = ServerConfiguration.Config()
        config.host = "0.0.0.0"
        config.port = 9001
        XCTAssertEqual(APIInformationMenu(config).openAI?.absoluteString, "http://127.0.0.1:9001/v1")
    }

    @MainActor
    func testASecretIsCopiedAsConcealed() {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        AddressActions.copySecret("llm-secret")
        XCTAssertEqual(pasteboard.string(forType: .string), "llm-secret")
        XCTAssertTrue(pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true)
    }
}
