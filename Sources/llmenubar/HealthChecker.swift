// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - HealthChecker

/// Polls Splash's HTTP endpoints to detect readiness and ongoing health.
///
/// Two endpoints, because they answer different questions. `/ready` is 200 only
/// once the engine holds the model, which is what "running" has to mean; but it
/// also reports 503 while macOS is under critical memory pressure, which says
/// nothing about whether the process is alive. Startup therefore waits on
/// `/ready`, and a running server is watched through `/health`, which answers
/// 200 for as long as Splash's HTTP server does.
///
/// This class is *stateless with respect to the UI* — it reports results via
/// closures so the owning ServerManager can publish @Published status changes
/// on the main actor.
@MainActor
final class HealthChecker {
    // MARK: - Callbacks (wired by ServerManager)

    /// Called when a health check succeeds for a server that was starting up.
    /// The orchestrator resolves the PID to report in the .running status.
    var onHealthSuccess: (() -> Void)?

    /// Called when a health check fails while the server was already running.
    var onUnreachable: ((String) -> Void)?

    /// Called once per start when a startup has been running for
    /// `stallAdvisoryInterval` without the listener coming up. This is an
    /// advisory only — nothing is terminated — so the user learns that a long
    /// startup is still in progress instead of watching an unchanging status.
    var onStartupStalled: (() -> Void)?

    /// A closure that can return whether the server is still in a starting-up
    /// state (.starting or .restarting).
    var isStartingUp: (() -> Bool)?

    /// A closure that can return whether the server was in .running state.
    var isRunning: (() -> Bool)?

    /// A closure that returns whether the child is deliberately held still (its
    /// log is being rotated). A stopped child cannot answer, and that is not
    /// an unresponsive one.
    var isPaused: (() -> Bool)?

    // MARK: - Private state

    /// Poll cadence while starting/restarting — fast, so the UI confirms
    /// "running" promptly once the server answers.
    private let fastInterval: Int
    /// Poll cadence once a run has been confirmed healthy.
    private let steadyInterval: Int
    /// How long a startup may run before the user gets an advisory. Chosen to be
    /// well past a normal large-model load, since it must never read as a
    /// deadline — a startup past this point is still perfectly valid.
    let stallAdvisoryInterval: TimeInterval

    /// A private session rather than `URLSession.shared`. The shared session's
    /// cookie and cache storage gives the process a CFNetwork storage database,
    /// and macOS attributes the assertion taken while that database is flushed
    /// to this app — which is why Activity Monitor reported LLMenuBar as
    /// preventing sleep despite the app holding no assertion of its own. A
    /// loopback readiness probe needs neither cookies nor a response cache.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// Consecutive failed polls required before a confirmed-healthy server is
    /// terminated. One failed poll used to be enough, which made any two-second
    /// stall fatal — a wake from sleep lands a poll while the server's pages are
    /// still being faulted back in, and nothing here knows a sleep happened.
    /// Three polls cost at most ~30s of extra detection latency, which nothing
    /// is waiting on, and the server they protect can take minutes to reload.
    let failureThreshold: Int

    /// The defaults are the production values; every one of them is a duration
    /// or a count that a test would otherwise have to wait out in real time.
    init(
        fastInterval: Int = 2,
        steadyInterval: Int = 10,
        stallAdvisoryInterval: TimeInterval = 600,
        failureThreshold: Int = 3
    ) {
        self.fastInterval = fastInterval
        self.steadyInterval = steadyInterval
        self.stallAdvisoryInterval = stallAdvisoryInterval
        self.failureThreshold = failureThreshold
    }

    /// Readable for tests; the run is only ever advanced or cleared here.
    private(set) var consecutiveFailures = 0
    var isPolling: Bool { healthTimer != nil }
    private var healthTimer: DispatchSourceTimer?
    private var readyURL: URL?
    private var livenessURL: URL?
    /// Set instead of the two URLs when Splash listens on a UNIX socket.
    private var socketPath: String?
    private var startupBegan: Date?
    private var stallAdvisoryPosted = false

    /// Bumped whenever polling starts, stops, or changes cadence. A response
    /// carrying a superseded generation is discarded, so a request still in
    /// flight when the run it belonged to ended cannot act on the one that
    /// replaced it — in particular, a slow failure landing after a success can
    /// no longer terminate a server that was just confirmed healthy.
    ///
    /// This and every other field here are touched only on the main queue.
    private var generation = 0

    // MARK: - Polling control

    /// Begin polling for readiness. There is deliberately no startup deadline:
    /// Splash may download a model, prepare it, and load the engine before it
    /// reports ready, and that duration depends heavily on the model, the
    /// network, memory pressure, and the Mac's current state.
    func startPolling(readyURL: URL, livenessURL: URL) {
        self.readyURL = readyURL
        self.livenessURL = livenessURL
        socketPath = nil
        beginPolling()
    }

    /// The same, for a Splash that listens on a UNIX socket.
    func startPolling(socketPath: String) {
        self.socketPath = socketPath
        readyURL = nil
        livenessURL = nil
        beginPolling()
    }

    private func beginPolling() {
        consecutiveFailures = 0
        startupBegan = Date()
        stallAdvisoryPosted = false
        scheduleHealthTimer(interval: fastInterval)
    }

    /// Stop all timers and reset state. Called when the server is stopped or
    /// restarted.
    func stop() {
        generation &+= 1
        healthTimer?.cancel(); healthTimer = nil
        consecutiveFailures = 0
        readyURL = nil
        livenessURL = nil
        socketPath = nil
        startupBegan = nil
        stallAdvisoryPosted = false
    }

    /// Recreate the health-poll timer at the given cadence. `firstDeadline`
    /// defaults to now for startup; after readiness, the next poll is delayed so
    /// the app does not immediately issue a duplicate request.
    private func scheduleHealthTimer(interval: Int, firstDeadline: DispatchTime = .now()) {
        generation &+= 1
        healthTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        timer.schedule(deadline: firstDeadline, repeating: .seconds(interval),
                       leeway: .seconds(max(1, interval / 2)))
        timer.setEventHandler { [weak self] in
            self?.checkHealth()
        }
        timer.resume()
        healthTimer = timer
    }

    // MARK: - Health check

    /// The timer fires on a background queue, so the request is issued from the
    /// main queue instead: every field this reads or writes lives there, and the
    /// generation stamped on the request has to be the one current at issue time.
    ///
    /// `nonisolated` states what is already true. The timer's event handler is a
    /// non-Sendable closure, so the compiler infers this class's main-actor
    /// isolation for it and then checks nothing — the handler still runs on a
    /// background queue. Declared this way, the hop below is the only way in,
    /// and an edit that reaches for main-queue state from here is a diagnostic
    /// rather than a silent race.
    nonisolated private func checkHealth() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            MainActor.assumeIsolated { self.issueHealthRequest() }
        }
    }

    private func issueHealthRequest() {
        if isPaused?() == true {
            consecutiveFailures = 0
            return
        }
        let starting = isStartingUp?() == true
        let issued = generation
        if let socketPath {
            let target = starting ? "/ready" : "/health"
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let result = UnixSocket.status(at: socketPath, target: target, timeout: 2)
                guard let s = self else { return }
                DispatchQueue.main.async {
                    switch result {
                    case .success(let code): s.handleAnswer(issued: issued, statusCode: code, errorText: nil)
                    case .failure(let error): s.handleAnswer(issued: issued, statusCode: nil, errorText: "\(error)")
                    }
                }
            }
            return
        }
        guard let url = starting ? readyURL : livenessURL else { return }
        let req = URLRequest(url: url, timeoutInterval: 2)
        Self.session.dataTask(with: req) { [weak self] _, response, error in
            guard let s = self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode
            let text = error.map { $0.localizedDescription }
            DispatchQueue.main.async { s.handleAnswer(issued: issued, statusCode: code, errorText: text) }
        }.resume()
    }

    /// What a poll found: a status code, or the reason there is none. Always on
    /// the main queue.
    private func handleAnswer(issued: Int, statusCode: Int?, errorText: String?) {
        let s = self
        // Superseded by a stop, a restart, or a cadence change.
        guard issued == s.generation else { return }
        if statusCode == 200 {
            // Server is alive and answering.
            s.consecutiveFailures = 0
            if s.isStartingUp?() == true {
                // PID is resolved by the orchestrator; we just signal success.
                s.startupBegan = nil
                s.onHealthSuccess?()
                // The lifecycle callback may synchronously stop or replace
                // this run. Do not recreate its timer after that decision.
                guard issued == s.generation else { return }
                s.scheduleHealthTimer(
                    interval: s.steadyInterval,
                    firstDeadline: .now() + .seconds(s.steadyInterval))
            }
        } else {
            let errMsg = errorText ?? "HTTP \(String(describing: statusCode))"
            // If it was running and now unreachable, report failure —
            // but only once a run of polls has failed, so a single
            // stalled request cannot kill a working server.
            if s.isRunning?() == true, s.isPaused?() != true {
                s.consecutiveFailures += 1
                if s.consecutiveFailures >= s.failureThreshold {
                    s.consecutiveFailures = 0
                    s.onUnreachable?(
                        "unreachable for \(s.failureThreshold) checks: \(errMsg)"
                    )
                }
            }
            guard issued == s.generation else { return }
            // If still starting, keep trying. Model loading and Metal
            // residency happen before the listener exists. Once past the
            // advisory interval, say so once — and keep polling.
            if s.isStartingUp?() == true, !s.stallAdvisoryPosted,
               let began = s.startupBegan,
               Date().timeIntervalSince(began) >= s.stallAdvisoryInterval {
                s.stallAdvisoryPosted = true
                s.onStartupStalled?()
            }
        }
    }
}
