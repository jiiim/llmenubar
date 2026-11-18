// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

/// A listener on a UNIX socket that answers each connection with one fixed
/// status line, as Splash's `/ready` and `/health` do. For the probe and the
/// health checker's socket mode.
final class UnixStubServer: @unchecked Sendable {
    /// Short: a socket path holds at most 103 bytes, which the temporary
    /// directory's own long name would exceed.
    let path: String
    private let listenFD: Int32
    private let lock = NSLock()
    private var _status = "200 OK"
    private var _paths: [String] = []
    private var _hosts: [String] = []
    private var stopped = false

    /// What follows `HTTP/1.1 ` on the answer. Anything else is a malformed one.
    var status: String {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }
    var requestPaths: [String] { lock.withLock { _paths } }
    var requestHosts: [String] { lock.withLock { _hosts } }

    init(path: String? = nil) {
        self.path = path ?? "/tmp/llmb-\(UUID().uuidString.prefix(8)).sock"
        unlink(self.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(fd >= 0, "socket() failed")
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(self.path.utf8CString)
        precondition(bytes.count <= MemoryLayout.size(ofValue: address.sun_path), "socket path too long")
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            for (index, byte) in bytes.enumerated() { destination[index] = UInt8(bitPattern: byte) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(bound == 0 && listen(fd, 8) == 0, "bind or listen failed")
        listenFD = fd
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    /// Stops answering and closes the listener. The socket file stays, as a
    /// killed server leaves it, unless `removeFile`.
    func stop(removeFile: Bool = true) {
        lock.withLock { stopped = true }
        shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
        if removeFile { unlink(path) }
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 || lock.withLock({ stopped }) {
                if client >= 0 { close(client) }
                return
            }
            var buffer = [UInt8](repeating: 0, count: 1024)
            let n = recv(client, &buffer, buffer.count, 0)
            if n > 0 {
                let request = String(decoding: buffer[..<n], as: UTF8.self)
                let lines = request.components(separatedBy: "\r\n")
                lock.withLock {
                    _paths.append(lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "")
                    _hosts.append(lines.first { $0.hasPrefix("Host: ") }.map { String($0.dropFirst(6)) } ?? "")
                }
                let line = lock.withLock { _status }
                let response = Array("HTTP/1.1 \(line)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                _ = response.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
            }
            close(client)
        }
    }
}
