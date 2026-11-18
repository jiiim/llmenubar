// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation
import os.log

@MainActor
final class PortWaiter {
    var onAvailable: (() -> Void)?
    private var generation = 0
    private var restartTimer: DispatchSourceTimer?
    let portWaitTimeout: TimeInterval
    private let log = OSLog(subsystem: "com.jiiim.llmenubar", category: "port-wait")
    init(timeout: TimeInterval) { portWaitTimeout = timeout }
    // MARK: - Port availability

    /// Start, but only after the listen port is actually free. The old process
    /// has already exited by the time we get here, yet the kernel can hold its
    /// port if another listener has taken over. Ignore closed TIME_WAIT
    /// connections, which Splash can reuse, and launch when no listener remains.
    ///
    /// When the port becomes available we invoke `onPortAvailable` rather than
    /// launching directly, so the orchestrator can set up health polling.
    func cancelPortWait() { generation &+= 1; restartTimer?.cancel(); restartTimer = nil }

    func startWhenPortAvailable(host: String, port: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        cancelPortWait()
        let issued = generation
        let completion = onAvailable
        if Self.isListenPortAvailable(host: host, port: port) {
            onAvailable?()
            return
        }
        // The probe can be stricter than the server's own bind — a host that
        // resolves to several addresses is probed on all of them — so something
        // else holding the port would otherwise pin the app in .restarting with
        // no recovery but a manual Stop. Past the deadline, relaunch anyway: the
        // launch's own port check then reports the port as in use.
        let deadline = Date().addingTimeInterval(portWaitTimeout)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.generation == issued else { return }
            let free = Self.isListenPortAvailable(host: host, port: port)
            guard free || Date() >= deadline else { return }
            if !free {
                os_log(.error, log: self.log,
                       "port %d still held after %.0fs; relaunching anyway",
                       port, self.portWaitTimeout)
            }
            self.restartTimer?.cancel(); self.restartTimer = nil
            completion?()
        }
        restartTimer = timer
        timer.resume()
    }

    /// Match Splash's reusable HTTP listener: TIME_WAIT is not a live owner.
    /// On macOS a reusable bind may also succeed beside a listener on a wider
    /// or narrower address. A bounded connection probe rejects that overlap.
    nonisolated static func isListenPortAvailable(host: String, port: Int) -> Bool {
        // A socket binds no port. It is taken while something accepts there or
        // a Splash holds its lock, as one does while its model loads; the file
        // a killed server leaves behind is replaced by the next one.
        if let socketPath = ListenAddress(host).socketPath {
            return !UnixSocket.isAccepting(at: socketPath) && !UnixSocket.isLockHeld(for: socketPath)
        }
        // Out of range, or 0 (which always binds to an ephemeral port and would
        // report a meaningless "available"): let launch surface the real error.
        guard let p = UInt16(exactly: port), p > 0 else { return true }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = numericOnly(host)
        var resolved: UnsafeMutablePointer<addrinfo>?
        // The configured host can arrive in URL form. getaddrinfo rejects the
        // brackets with EAI_NONAME, and an unresolvable host reads as "port
        // free" just below — silently skipping the very wait this drives — so
        // normalize here rather than trusting every caller to remember.
        let bare = ListenAddress(host).bare
        guard getaddrinfo(bare, String(p), &hints, &resolved) == 0, resolved != nil else {
            return true  // unresolvable: launch reports it far more clearly than a stalled wait
        }
        defer { freeaddrinfo(resolved) }

        var candidate = resolved
        while let current = candidate {
            let fd = socket(current.pointee.ai_family,
                            current.pointee.ai_socktype,
                            current.pointee.ai_protocol)
            // A family this machine cannot open (no IPv6, say) is not a port
            // conflict — skip it rather than reporting the port as held.
            if fd >= 0 {
                var reuse: Int32 = 1
                guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse,
                                 socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                    close(fd)
                    return false
                }
                let rc = bind(fd, current.pointee.ai_addr, current.pointee.ai_addrlen)
                let bindError = errno
                close(fd)
                // Only a taken port is a conflict. An address this Mac does not
                // hold, or one it may not bind, is the engine's own error to
                // report; calling it "in use" would misname it.
                if rc != 0, bindError == EADDRINUSE { return false }
            }
            candidate = current.pointee.ai_next
        }
        return !hasListener(host: ListenAddress(host).reachableSocketHost, port: p)
    }

    /// An address needs no lookup. Telling the resolver so keeps a probe on the
    /// main actor from waiting on DNS; only a host name is ever resolved.
    nonisolated private static func numericOnly(_ host: String) -> Int32 {
        ListenAddress(host).kind == .name ? 0 : AI_NUMERICHOST
    }

    /// A connection is only a liveness probe, never an HTTP request. Limit the
    /// wait so an unusual interface/address cannot stall the main actor.
    nonisolated private static func hasListener(host: String, port: UInt16) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = numericOnly(host)
        var resolved: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &resolved) == 0 else { return false }
        defer { freeaddrinfo(resolved) }
        var candidate = resolved
        while let address = candidate {
            candidate = address.pointee.ai_next
            let fd = socket(address.pointee.ai_family, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                close(fd)
                continue
            }
            let result = connect(fd, address.pointee.ai_addr, address.pointee.ai_addrlen)
            if result == 0 { close(fd); return true }
            if errno == EINPROGRESS {
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&descriptor, 1, 100) > 0 {
                    var error: Int32 = 0
                    var size = socklen_t(MemoryLayout<Int32>.size)
                    if getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 {
                        close(fd)
                        return true
                    }
                }
            }
            close(fd)
        }
        return false
    }

}
