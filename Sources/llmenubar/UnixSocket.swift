// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

/// Reaching a Splash that listens on a UNIX socket (`--host unix:PATH`).
///
/// `URLSession` takes no socket path, and a probe needs nothing more than one
/// request line and a status code, so the probe speaks that much HTTP itself.
/// Every call blocks for at most its timeout; call them off the main thread,
/// except `isAccepting`, which returns at once.
enum UnixSocket {
    enum ProbeError: Error, Equatable {
        case notConnected(String)
        case noAnswer
        case notHTTP
    }

    /// The `Host` a probe sends. Splash accepts `localhost`, a loopback address
    /// and the names it was given with `--allowed-host`.
    static let hostName = "localhost"

    /// Whether something accepts connections at `path`. A socket file nothing
    /// listens on (the one a killed server leaves) is not accepting, and a
    /// missing file is not either.
    static func isAccepting(at path: String) -> Bool {
        guard let fd = connectedSocket(to: path) else { return false }
        close(fd)
        return true
    }

    /// Whether a Splash holds the lock beside the socket, `PATH.lock`. It takes
    /// the lock before it binds and keeps it until it has removed the socket,
    /// so this is true while the model loads, when nothing accepts yet. The
    /// probe asks for a shared lock without waiting and lets it go at once.
    static func isLockHeld(for path: String) -> Bool {
        let fd = open(path + ".lock", O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    /// The status code of `GET target`, or why there is none.
    static func status(
        at path: String, target: String, timeout: TimeInterval
    ) -> Result<Int, ProbeError> {
        guard let fd = connectedSocket(to: path) else {
            return .failure(.notConnected(String(cString: strerror(errno))))
        }
        defer { close(fd) }
        var wait = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

        let request = Array("GET \(target) HTTP/1.1\r\nHost: \(hostName)\r\nConnection: close\r\n\r\n".utf8)
        var sent = 0
        while sent < request.count {
            let n = request[sent...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { return .failure(.noAnswer) }
            sent += n
        }

        // The status line is all that is read: `HTTP/1.1 200 OK`.
        var received = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 256)
        while received.count < 256, !received.contains(0x0A) {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            received.append(contentsOf: buffer[..<n])
        }
        guard !received.isEmpty else { return .failure(.noAnswer) }
        return parseStatus(Data(received))
    }

    /// The code in the first line of a response.
    static func parseStatus(_ response: Data) -> Result<Int, ProbeError> {
        let line = String(decoding: response, as: UTF8.self)
            .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let code = Int(parts[1]) else {
            return .failure(.notHTTP)
        }
        return .success(code)
    }

    /// A socket connected to `path`, or nil with `errno` set. The connection is
    /// made without blocking: a listener whose queue is full refuses at once
    /// rather than holding the caller.
    private static func connectedSocket(to path: String) -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            errno = ENAMETOOLONG
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            for (index, byte) in bytes.enumerated() { destination[index] = UInt8(bitPattern: byte) }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            close(fd)
            return nil
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            let reason = errno
            close(fd)
            errno = reason
            return nil
        }
        // Back to blocking, so the reads and writes obey their timeouts.
        _ = fcntl(fd, F_SETFL, flags)
        return fd
    }
}
