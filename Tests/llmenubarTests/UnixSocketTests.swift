// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest

@testable import llmenubar

final class UnixSocketTests: XCTestCase {
    func testTheStatusOfARequestIsRead() {
        let server = UnixStubServer()
        defer { server.stop() }

        XCTAssertEqual(UnixSocket.status(at: server.path, target: "/ready", timeout: 2), .success(200))
        server.status = "503 Service Unavailable"
        XCTAssertEqual(UnixSocket.status(at: server.path, target: "/health", timeout: 2), .success(503))
        XCTAssertEqual(server.requestPaths, ["/ready", "/health"])
        XCTAssertEqual(Set(server.requestHosts), ["localhost"], "Splash accepts localhost as the Host")
    }

    func testSomethingThatIsNotHTTPIsNotAStatus() {
        let server = UnixStubServer()
        defer { server.stop() }
        server.status = "banana"
        XCTAssertEqual(UnixSocket.status(at: server.path, target: "/ready", timeout: 2), .failure(.notHTTP))
        XCTAssertEqual(UnixSocket.parseStatus(Data("SSH-2.0-OpenSSH\r\n".utf8)), .failure(.notHTTP))
        XCTAssertEqual(UnixSocket.parseStatus(Data("HTTP/1.1 204 No Content\r\n".utf8)), .success(204))
        XCTAssertEqual(UnixSocket.parseStatus(Data()), .failure(.notHTTP))
    }

    func testAMissingSocketCannotBeReached() {
        let path = "/tmp/llmb-missing-\(UUID().uuidString.prefix(8)).sock"
        XCTAssertFalse(UnixSocket.isAccepting(at: path))
        guard case .failure(.notConnected) = UnixSocket.status(at: path, target: "/ready", timeout: 1) else {
            return XCTFail("a path with no socket is not connected")
        }
    }

    func testAStaleSocketFileIsNotAServer() {
        let server = UnixStubServer()
        XCTAssertTrue(UnixSocket.isAccepting(at: server.path))
        // Closed without removing the file, as a killed server leaves it.
        server.stop(removeFile: false)
        defer { unlink(server.path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: server.path))
        XCTAssertFalse(UnixSocket.isAccepting(at: server.path), "nothing accepts there, so the next server may replace it")
    }

    func testAPathTooLongForASocketIsRefusedNotCrashed() {
        let path = "/tmp/" + String(repeating: "x", count: 200)
        XCTAssertFalse(UnixSocket.isAccepting(at: path))
        guard case .failure = UnixSocket.status(at: path, target: "/ready", timeout: 1) else {
            return XCTFail("an over-long path cannot connect")
        }
    }

    func testThePortCheckForASocketHostAsksWhetherItAccepts() {
        let server = UnixStubServer()
        let host = "unix:" + server.path
        XCTAssertFalse(PortWaiter.isListenPortAvailable(host: host, port: 8000), "a live server holds the socket")
        server.stop(removeFile: false)
        defer { unlink(server.path) }
        XCTAssertTrue(PortWaiter.isListenPortAvailable(host: host, port: 8000), "a stale file is replaced")
    }

    /// Splash takes `PATH.lock` before it binds and keeps it while its model
    /// loads, when nothing accepts on the socket yet.
    func testALockBesideTheSocketMeansAServerIsStillLoading() {
        let path = "/tmp/llmb-lock-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(path + ".lock") }
        XCTAssertFalse(UnixSocket.isLockHeld(for: path), "no lock file, no server")

        let holder = open(path + ".lock", O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(holder, 0)
        XCTAssertFalse(UnixSocket.isLockHeld(for: path), "a file nobody holds is a stale one")
        XCTAssertTrue(PortWaiter.isListenPortAvailable(host: "unix:" + path, port: 8000))

        XCTAssertEqual(flock(holder, LOCK_EX | LOCK_NB), 0)
        XCTAssertTrue(UnixSocket.isLockHeld(for: path))
        XCTAssertFalse(UnixSocket.isAccepting(at: path), "nothing accepts yet")
        XCTAssertFalse(PortWaiter.isListenPortAvailable(host: "unix:" + path, port: 8000),
                       "so the socket is taken all the same")

        close(holder)
        XCTAssertFalse(UnixSocket.isLockHeld(for: path), "released when the server exits")
        XCTAssertTrue(PortWaiter.isListenPortAvailable(host: "unix:" + path, port: 8000))
    }
}
