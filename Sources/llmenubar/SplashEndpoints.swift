// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import AppKit
import Foundation

/// The addresses a configured server answers at, as reached from this Mac.
/// What Settings and the menu show, open and copy.
struct SplashEndpoints: Equatable, Sendable {
    /// The browser chat page.
    let chatPage: URL?
    /// The base URL OpenAI SDKs and clients take.
    let openAIBase: URL?
    /// The base URL Anthropic SDKs and clients take.
    let anthropicBase: URL?
    /// The path of the socket, when the server listens on one. No URL reaches
    /// it, so the three above are nil then.
    let socketPath: String?

    init(host: String, port: Int) {
        let address = ListenAddress(host)
        chatPage = address.url(port: port, path: "/")
        openAIBase = address.url(port: port, path: "/v1")
        anthropicBase = address.url(port: port, path: "")
        socketPath = address.socketPath
    }

    /// Whether the menu's address line opens the chat page: the server is
    /// running and serves one.
    static func opensChatPage(status: ServerStatus, chatPageEnabled: Bool) -> Bool {
        guard chatPageEnabled else { return false }
        if case .running = status { return true }
        return false
    }

    init(_ configuration: ServerConfiguration.Config) {
        self.init(host: configuration.host, port: configuration.port)
    }
}

/// The context window the Qwen families are built with, in tokens: 256K,
/// where K is 1024. Splash serves up to it without YaRN. Inkling-2-Mini has
/// a window of its own, `inklingTokens`.
enum NativeContextWindow {
    static let tokens = 262_144
    /// Inkling-2-Mini's window, 1024K, and the most Splash serves of it.
    static let inklingTokens = 1_048_576
    static let inklingServedTokens = 1_010_000

    /// `262,144 tokens (256K)`, with commas in every locale.
    static var description: String { description(of: tokens) }

    /// `1,048,576 tokens (1024K)`.
    static func description(of tokens: Int) -> String {
        "\(grouped(tokens)) tokens (\(tokens / 1_024)K)"
    }

    /// `1,010,000`, with commas in every locale.
    static func grouped(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
    }

    /// What the Context length setting says of the window of the model
    /// `config` serves.
    static func note(for config: ServerConfiguration.Config) -> String {
        let units = "Tokens, with K for 1024 or M for a million, such as 100K or 1M."
        if ModelFamily.isInkling(config) {
            return "\(units) The native window is \(description(of: inklingTokens)), and the engine serves up to \(grouped(inklingServedTokens)) of them. Auto serves as much as memory holds."
        }
        return "\(units) The native window is \(description). Past it the engine turns on YaRN, which changes answers at every length. Auto serves the native window when memory holds it, and otherwise as much as memory holds."
    }
}

/// What the menu's "API Information" submenu offers for a configuration.
struct APIInformationMenu: Equatable {
    static let keyTitle = "Copy API Key"
    static let keyTitleWhenNotSet = "Copy API Key (not set)"
    /// The subtitle under the engine line while it opens the chat page.
    static let openChatSubtitle = "Open Chat in Browser"

    let anthropic: URL?
    let openAI: URL?
    let keyTitle: String
    let keyIsAvailable: Bool

    init(_ configuration: ServerConfiguration.Config) {
        let endpoints = SplashEndpoints(configuration)
        anthropic = endpoints.anthropicBase
        openAI = endpoints.openAIBase
        keyIsAvailable = !configuration.apiKey.trimmingCharacters(in: .whitespaces).isEmpty
        keyTitle = keyIsAvailable ? Self.keyTitle : Self.keyTitleWhenNotSet
    }
}

enum AddressActions {
    @MainActor
    static func copy(_ url: URL) {
        copy(url.absoluteString)
    }

    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Copy a secret. Clipboard managers that follow the convention skip what
    /// is marked concealed.
    @MainActor
    static func copySecret(_ text: String) {
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, concealed], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: concealed)
    }

    @MainActor
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
