// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import SystemConfiguration

/// The names by which other devices on the network reach this Mac. When Splash
/// listens on every interface, `127.0.0.1` is no address to give a client on
/// another machine.
struct LocalNetworkNames: Equatable, Sendable {
    /// `Name.local`, the Bonjour host name, if the Mac has one.
    var hostName: String?
    /// The first private IPv4 address of a network interface that is up.
    var ipv4: String?

    static func current() -> LocalNetworkNames {
        let local = SCDynamicStoreCopyLocalHostName(nil) as String?
        return LocalNetworkNames(
            hostName: local.flatMap { $0.isEmpty ? nil : $0 + ".local" },
            ipv4: firstIPv4()
        )
    }

    /// Lowest-numbered `en` interface first, so Wi-Fi or the built-in Ethernet
    /// comes before a bridge or a VPN. Loopback and link-local addresses are no
    /// use to another device.
    private static func firstIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let sockaddr = entry.ifa_addr, sockaddr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var address = sockaddr_in()
            memcpy(&address, sockaddr, MemoryLayout<sockaddr_in>.size)
            guard inet_ntop(AF_INET, &address.sin_addr, &buffer, socklen_t(buffer.count)) != nil else { continue }
            let text = String(cString: buffer)
            guard !text.hasPrefix("169.254.") else { continue }
            found.append((name, text))
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.first?.address
    }
}

/// The base URLs another device would use, one entry per way of naming this Mac.
struct OtherDeviceEndpoints: Equatable {
    let label: String
    let openAI: URL?
    let anthropic: URL?

    /// Empty unless the server listens on every interface: otherwise the
    /// address already shown is the one clients use.
    static func entries(host: String, port: Int, names: LocalNetworkNames) -> [OtherDeviceEndpoints] {
        guard ListenAddress(host).isUnspecified else { return [] }
        return [names.hostName, names.ipv4].compactMap { $0 }.map { label in
            let address = ListenAddress(label)
            return OtherDeviceEndpoints(
                label: label,
                openAI: address.url(port: port, path: "/v1"),
                anthropic: address.url(port: port, path: "")
            )
        }
    }
}
