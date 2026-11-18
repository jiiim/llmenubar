// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

/// The address Splash is told to listen on, and the address this app uses to
/// reach it.
///
/// The two differ whenever Splash listens on every interface. An unspecified
/// address (`0.0.0.0` or `::`) says where a server accepts connections; it is
/// no place a client can connect to. The readiness probe and the port check
/// therefore use a loopback address in its place, while Splash still receives
/// the configured address unchanged.
struct ListenAddress: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case unspecifiedIPv4
        case unspecifiedIPv6
        case ipv4
        case ipv6
        case name
        /// `unix:PATH`: a UNIX socket, which no IP address reaches.
        case unixSocket
    }

    static let unixPrefix = "unix:"
    /// The longest socket path macOS takes, in bytes, as Splash states it.
    static let maxSocketPathBytes = 103

    /// The host as typed, trimmed.
    let configured: String
    let kind: Kind

    init(_ configured: String) {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        self.configured = trimmed
        kind = trimmed.hasPrefix(Self.unixPrefix)
            ? .unixSocket
            : Self.classify(Self.removingBrackets(trimmed))
    }

    /// The path of a `unix:PATH` address, with `~` expanded; nil for any other.
    var socketPath: String? {
        guard kind == .unixSocket else { return nil }
        return PathText.expandingTilde(String(configured.dropFirst(Self.unixPrefix.count)))
    }

    /// The form a socket call and Splash's `--host` take. URL syntax wraps an
    /// IPv6 address in brackets to set it apart from the port; the address
    /// itself has none.
    var bare: String {
        if let socketPath { return Self.unixPrefix + socketPath }
        return Self.removingBrackets(configured)
    }

    var isUnspecified: Bool {
        kind == .unspecifiedIPv4 || kind == .unspecifiedIPv6
    }

    /// The host component of a URL that reaches this listener from this Mac.
    var reachableURLHost: String {
        switch kind {
        case .unspecifiedIPv4: return "127.0.0.1"
        case .unspecifiedIPv6: return "[::1]"
        case .ipv6: return "[\(bare)]"
        case .ipv4, .name: return bare
        // The name a request to the socket carries in its Host header.
        case .unixSocket: return "localhost"
        }
    }

    /// The same, as a host for a socket call, with no brackets.
    var reachableSocketHost: String {
        switch kind {
        case .unspecifiedIPv4: return "127.0.0.1"
        case .unspecifiedIPv6: return "::1"
        case .ipv4, .ipv6, .name, .unixSocket: return bare
        }
    }

    /// `host:port` for display, with an IPv6 address bracketed so the port stays
    /// readable. An unspecified address is shown as configured: that Splash
    /// listens on every interface is the point of showing it.
    func displayed(port: Int) -> String {
        // A socket has no port to show: the address is its path.
        if kind == .unixSocket { return configured }
        let host = bare.contains(":") ? "[\(bare)]" : bare
        return "\(host):\(port)"
    }

    /// The URL of one of Splash's endpoints, as reached from this Mac.
    ///
    /// Nil for a host that cannot be part of a URL. `percentEncodedHost` traps
    /// on text it cannot hold, so nothing unchecked reaches it.
    func url(port: Int, path: String) -> URL? {
        // No browser or SDK takes a socket, so there is no URL to give.
        guard isWellFormed, kind != .unixSocket else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.percentEncodedHost = reachableURLHost
        components.port = port
        components.path = path
        return components.url
    }

    /// Whether this Splash can listen on IPv6 addresses. 1.6.1's `--host` takes
    /// an IPv4 bind address. A future engine, or a Splash that learns IPv6,
    /// changes this one value.
    static let acceptsIPv6 = false

    /// A host name: letters, digits, dots and hyphens, in labels of at most 63
    /// characters that neither start nor end with a hyphen.
    static func isHostName(_ text: String) -> Bool {
        let name = text.hasSuffix(".") ? String(text.dropLast()) : text
        guard !name.isEmpty, name.count <= 253 else { return false }
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.count <= 63
                && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    /// Whether the host can be used in a URL and handed to Splash as it is.
    var isWellFormed: Bool {
        switch kind {
        case .name: return Self.isHostName(bare)
        // inet_pton accepts a zone suffix (`fe80::1%en0`), which a URL host
        // cannot hold.
        case .ipv6, .unspecifiedIPv6:
            return bare.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
        case .ipv4, .unspecifiedIPv4: return true
        case .unixSocket: return socketIssue == nil
        }
    }

    /// Why a `unix:PATH` address cannot be used, or nil. The path is absolute
    /// or starts with `~`, is at most `maxSocketPathBytes` long, and holds no
    /// control character.
    var socketIssue: String? {
        guard let path = socketPath else { return nil }
        if configured.dropFirst(Self.unixPrefix.count).trimmingCharacters(in: .whitespaces).isEmpty {
            return "Enter the socket's path after unix:, such as unix:~/splash.sock."
        }
        if !PathText.isAbsolute(path) {
            return "Use a full path, or one that starts with ~, such as unix:~/splash.sock."
        }
        if path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) {
            return "A socket path cannot contain control characters."
        }
        if path.utf8.count > Self.maxSocketPathBytes {
            return "A socket path is at most \(Self.maxSocketPathBytes) bytes, the longest macOS takes. This one has \(path.utf8.count)."
        }
        return nil
    }

    /// Whether only this Mac can reach the listener: `127.x.x.x`, `::1` or
    /// `localhost`. Any other address, `0.0.0.0` included, is open to a network.
    var isLoopback: Bool {
        switch kind {
        case .ipv4: return bare.hasPrefix("127.")
        case .ipv6: return bare == "::1"
        case .name: return bare.lowercased() == "localhost"
        // File permissions decide who connects; no network reaches a socket.
        case .unixSocket: return true
        case .unspecifiedIPv4, .unspecifiedIPv6: return false
        }
    }

    var isIPv6: Bool { kind == .ipv6 || kind == .unspecifiedIPv6 }

    private static func removingBrackets(_ text: String) -> String {
        guard text.count > 2, text.hasPrefix("["), text.hasSuffix("]") else { return text }
        return String(text.dropFirst().dropLast())
    }

    private static func classify(_ bare: String) -> Kind {
        var v4 = in_addr()
        if inet_pton(AF_INET, bare, &v4) == 1 {
            return v4.s_addr == 0 ? .unspecifiedIPv4 : .ipv4
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, bare, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            let allZero = bytes.allSatisfy { $0 == 0 }
            // ::ffff:0.0.0.0 is the IPv4 unspecified address in IPv6 dress.
            let mappedZero = bytes[..<10].allSatisfy { $0 == 0 }
                && bytes[10] == 0xff && bytes[11] == 0xff
                && bytes[12...].allSatisfy { $0 == 0 }
            return allZero || mappedZero ? .unspecifiedIPv6 : .ipv6
        }
        return .name
    }
}
