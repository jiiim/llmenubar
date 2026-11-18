// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation
import os.log

// MARK: - TerminationInfo
//
// Passed to the termination callback so the orchestrator (ServerManager) can
// decide the next status and whether to post a user notification.

struct TerminationInfo: Sendable { let clean: Bool }

// MARK: - ProcessManager
//
/// Executes process operations and reports cleanup completion. Restart and
/// failure policy belong exclusively to ServerLifecycle. Log and port resources
/// are delegated to dedicated adapters.

@MainActor
final class ProcessManager {
    // MARK: - Callbacks (wired by ServerManager)

    /// Called when the child process has fully terminated.
    var onTerminated: ((TerminationInfo) -> Void)?

    /// Called by startWhenPortAvailable once the listen port is free.
    /// The orchestrator should respond by calling its own start() so health
    /// polling is wired up correctly.
    var onPortAvailable: (() -> Void)? {
        get { portWaiter.onAvailable }
        set { portWaiter.onAvailable = newValue }
    }

    /// Called for failures that prevent a launch from creating a child process.
    /// ServerManager adds the launch source and chooses the user-facing route.
    var onLaunchFailure: ((String) -> Void)?

    /// A failed signal must not be reported as completed shutdown.
    var onTerminationFailure: ((String) -> Void)?

    /// Called when Splash's log reports a request phase or average rate.
    var onPerformanceChange: ((ServerPerformance) -> Void)? {
        get { logSession.onPerformanceChange }
        set { logSession.onPerformanceChange = newValue }
    }

    /// Called when Splash's log says it gave the weights back after an idle
    /// spell, or took them again for a request. Reported whether or not the
    /// speed is shown.
    var onWeightsChange: ((WeightsEvent) -> Void)? {
        get { logSession.onWeightsChange }
        set { logSession.onWeightsChange = newValue }
    }

    // MARK: - Private state

    private var process: Process?
    /// Identifies the launch that owns `process` and `logFileHandle`. A
    /// termination handler carrying a stale ID belongs to a run that has already
    /// been replaced, and must not finalize the current run's state.
    private var currentRunID: UUID?
    let logSession = ServerLogSession()
    private var logFileHandle: FileHandle? {
        get { logSession.logFileHandle }
        set { logSession.logFileHandle = newValue }
    }
    private let log = OSLog(subsystem: "com.jiiim.llmenubar", category: "server")

    var lastUsageAt: Date? { logSession.lastUsageAt }

    /// The child is suspended while its log is copied; polling it then says nothing.
    var isRotatingLog: Bool { logSession.isRotating }

    /// Timer used to poll for port availability after a restart's stop phase.
    private let portWaiter: PortWaiter

    /// One forced kill per termination: SIGTERM first, then SIGKILL if the child
    /// has not exited after `forceKillGrace`. A stopped or wedged server cannot
    /// act on SIGTERM, and without this bound it would hold its port and the
    /// menu forever. Injectable so tests do not wait real time.
    private var forceKillTimer: DispatchSourceTimer?
    let forceKillGrace: TimeInterval
    let portWaitTimeout: TimeInterval
    private let listenPortAvailable: (String, Int) -> Bool
    /// Bytes in one configured megabyte. Tests shrink it to rotate small logs.
    let bytesPerLogMB: Int

    // MARK: - Init

    init(forceKillGrace: TimeInterval = 30, portWaitTimeout: TimeInterval = 10,
         bytesPerLogMB: Int = 1024 * 1024,
         listenPortAvailable: @escaping (String, Int) -> Bool = {
             ProcessManager.isListenPortAvailable(host: $0, port: $1)
         }) {
        self.listenPortAvailable = listenPortAvailable
        self.bytesPerLogMB = bytesPerLogMB
        self.forceKillGrace = forceKillGrace
        self.portWaitTimeout = portWaitTimeout
        self.portWaiter = PortWaiter(timeout: portWaitTimeout)
    }

    // MARK: - Launch

    /// Where the health checker polls: `/ready` while the model loads,
    /// `/health` once the server is running, at two URLs or at one socket.
    enum HealthEndpoints: Equatable {
        case http(ready: URL, liveness: URL)
        case unixSocket(path: String)

        var ready: URL? {
            if case .http(let ready, _) = self { return ready }
            return nil
        }

        var liveness: URL? {
            if case .http(_, let liveness) = self { return liveness }
            return nil
        }
    }

    /// Build and run the `splash serve` child process with the given
    /// configuration. Returns the health endpoints on success, or nil if
    /// pre-flight checks or launch failed (reported through onLaunchFailure).
    ///
    /// Nothing here runs the executable to ask about it: that blocks, and this
    /// is the main queue. Settings inspected the executable when the
    /// configuration was applied; an option a newer or older Splash refuses
    /// lands in the log, which `launchFailureReason` reads.
    @discardableResult
    func launch(configuration: ServerConfiguration.Config) -> HealthEndpoints? {
        dispatchPrecondition(condition: .onQueue(.main))
        portWaiter.cancelPortWait()
        forceKillTimer?.cancel(); forceKillTimer = nil

        let resolvedSplashPath = PathText.expandingTilde(configuration.splashPath)

        // Persisted or externally edited configuration must not bypass basic
        // file checks at the process boundary.
        guard case .success(let launcher) = SplashLauncher.resolve(path: resolvedSplashPath) else {
            return failLaunch("splash not found or not executable at \(resolvedSplashPath)")
        }
        if configuration.modelSource == .local {
            if case .failure(let issue) = SplashModel.inspectLocalModel(atPath: configuration.modelPath) {
                return failLaunch(issue.launchMessage(at: PathText.expandingTilde(configuration.modelPath)))
            }
            let projector = PathText.expandingTilde(configuration.visionProjectorPath)
            if !configuration.languageOnly, !projector.isEmpty,
               !FileManager.default.isReadableRegularFile(atPath: projector) {
                return failLaunch("vision projector not readable at \(projector)")
            }
        }
        let template = PathText.expandingTilde(configuration.chatTemplatePath)
        if !template.isEmpty, !FileManager.default.isReadableRegularFile(atPath: template) {
            return failLaunch("chat template not readable at \(template)")
        }
        if let firstError = configuration.firstValidationError() {
            return failLaunch("Invalid server configuration: \(firstError)")
        }

        let address = ListenAddress(configuration.host)
        let endpoints: HealthEndpoints
        if let socketPath = address.socketPath {
            endpoints = .unixSocket(path: socketPath)
        } else if let readyURL = address.url(port: configuration.port, path: "/ready"),
                  let livenessURL = address.url(port: configuration.port, path: "/health") {
            endpoints = .http(ready: readyURL, liveness: livenessURL)
        } else {
            return failLaunch("Unable to construct a health-check URL for host \(configuration.host)")
        }

        guard listenPortAvailable(configuration.host, configuration.port) else {
            if let socketPath = address.socketPath {
                return failLaunch(
                    "A server already holds the socket \(socketPath). An engine from an earlier session may still be running: "
                    + "find it in Activity Monitor, or stop it before starting another.")
            }
            return failLaunch(
                "The listen port \(configuration.port) is already in use. An engine from an earlier session may still be running: "
                + "find it in Activity Monitor, or run lsof -nP -iTCP:\(configuration.port) -sTCP:LISTEN in Terminal.")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launcher.executable)
        let args = SplashCommand.arguments(configuration: configuration)
        proc.arguments = launcher.leadingArguments + args
        proc.environment = SplashCommand.launchEnvironment(configuration: configuration, launcher: launcher)
        // Splash resolves nothing relative to where it starts, and the app has
        // no meaningful directory of its own, so say which one it is.
        let workingDirectory = FileManager.default.homeDirectoryForCurrentUser
        proc.currentDirectoryURL = workingDirectory

        // Open the log in append-only mode — do NOT truncate, so logs
        // accumulate across restarts. Both stdout and stderr go straight to it.
        let logPathResolved = PathText.expandingTilde(configuration.logPath)
        let fm = FileManager.default
        // The SSD cache holds prompt text and model state. Splash creates its
        // default location itself; a folder the user chose is created here so
        // it is owner-only rather than whatever umask Splash runs with.
        if configuration.persistentCache, !configuration.cacheDirectory.isEmpty {
            ServerLogSession.createOwnerOnlyDirectory(
                PathText.expandingTilde(configuration.cacheDirectory),
                fm: fm
            )
        }
        let maxLogBytes = configuration.logMaxSizeMB * bytesPerLogMB
        guard let handle = logSession.openLog(at: logPathResolved, maximumBytes: maxLogBytes) else {
            cleanup()
            return failLaunch("Unable to open server log at \(logPathResolved)")
        }
        let fd = handle.fileDescriptor
        proc.standardOutput = handle

        // Launch header — exactly what was run and where.
        logSession.writeLog("=== llmenubar launch \(Self.timestamp()) ===\n")
        logSession.writeLog("exec: \(([launcher.executable] + launcher.leadingArguments).joined(separator: " "))\n")
        logSession.writeLog("cwd:  \(workingDirectory.path)\n")
        let overrides = SplashCommand.environmentOverrides(configuration: configuration)
        if !overrides.isEmpty {
            // Secret values (the API key, tokens) stay out of the log.
            let rendered = overrides.map { name, value in
                EnvironmentText.isSecret(name) ? "\(name)=REDACTED" : "\(name)=\(value)"
            }
            logSession.writeLog("env:  \(rendered.joined(separator: " "))\n")
        }
        logSession.writeLog("argv: \(args.joined(separator: " "))\n")
        logSession.writeLog("---\n")

        // Both stdout and stderr go directly to the log file — no pipe,
        // no dispatch source, no race between async reads and termination.
        proc.standardError = handle

        // Identifies this launch for the termination handler. A later launch
        // mints a new one, which is how a late handler recognizes that the
        // state it would finalize is no longer its own.
        let runID = UUID()

        // Fires on a Foundation-internal queue. It touches none of this class's
        // state there: every field below is main-queue-only, and closing the log
        // from the callback queue raced `cleanup()` into a double close.
        proc.terminationHandler = { [weak self] p in
            // Both streams write directly to the log file, so there's no pipe
            // to drain — the termination handler only needs to close the file.
            let clean = (p.terminationReason == .exit && p.terminationStatus == 0)
            // Resolve the weak reference here rather than inside the hop: the
            // main block then captures an immutable binding instead of this
            // closure's mutable capture.
            let manager = self

            DispatchQueue.main.async {
                guard let self = manager else {
                    handle.closeFile()
                    return
                }
                // A relaunch may already own `logFileHandle` and `process` by
                // the time this lands. Close only the handle this run opened and
                // leave the newer run's state alone — finalizing it here would
                // close the live log and drop the live process reference.
                //
                // Keyed on the run rather than on `process === p`, because
                // `terminate()` nils `process` when it finds the child already
                // reaped; that path still owes the orchestrator its callback.
                guard self.currentRunID == runID else {
                    handle.closeFile()
                    return
                }
                handle.closeFile()
                self.logSession.stopLogMonitoring { [weak self] in
                    guard let self, self.currentRunID == runID else { return }
                    self.currentRunID = nil
                    self.logFileHandle = nil
                    self.process = nil
                    self.portWaiter.cancelPortWait()
                    self.forceKillTimer?.cancel(); self.forceKillTimer = nil
                    self.onTerminated?(TerminationInfo(clean: clean))
                }
            }
        }

        do {
            try proc.run()
            process = proc
            currentRunID = runID
            logSession.startLogMonitoring(
                path: logPathResolved,
                maximumBytes: maxLogBytes,
                process: proc,
                fileDescriptor: fd
            )
            return endpoints
        } catch {
            let message = "failed to launch: \(error.localizedDescription)"
            logSession.writeLog("\(message)\n")
            cleanup()
            return failLaunch(message)
        }
    }

    private func failLaunch(_ message: String) -> HealthEndpoints? {
        onLaunchFailure?(message)
        return nil
    }

    // MARK: - Terminate

    /// Send SIGTERM to the child process. Also the cancel path for an in-progress
    /// start or restart — the caller should have cancelled any health/startup
    /// timers before invoking this.
    ///
    /// An explicit stop clears any recorded failure first. A Stop during the
    /// grace after a health failure must be reported as Stopped, not as the
    /// failure it interrupted, and must never feed an automatic restart.
    func terminate() {
        terminateProcess()
    }

    private func terminateProcess() {
        dispatchPrecondition(condition: .onQueue(.main))
        portWaiter.cancelPortWait()

        guard let proc = process, proc.isRunning else {
            // No live child (already stopped/errored, or waiting on a port).
            process = nil
            return
        }

        logSession.cancelLogRotation(for: proc)
        proc.terminate()  // SIGTERM
        scheduleForcedKill(for: proc)
    }

    /// Arm the single forced kill for this run. Repeated terminations do not
    /// postpone it, and it fires only while the same run still owns the
    /// process, so a stale timer can never hit a replacement.
    private func scheduleForcedKill(for proc: Process) {
        guard forceKillTimer == nil, let runID = currentRunID else { return }
        let pid = proc.processIdentifier
        let grace = forceKillGrace
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + grace)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard self.currentRunID == runID, self.process === proc, proc.isRunning else {
                return
            }
            self.forceKillTimer?.cancel(); self.forceKillTimer = nil
            self.logSession.writeLog("SIGTERM not answered after \(Int(grace))s; sending SIGKILL\n")
            if kill(pid, SIGKILL) != 0, errno != ESRCH {
                let message = "Unable to stop the engine: \(String(cString: strerror(errno)))"
                self.logSession.writeLog(message + "\n")
                self.onTerminationFailure?(message)
            }
        }
        forceKillTimer = timer
        timer.resume()
    }

    func cancelPortWait() { portWaiter.cancelPortWait() }
    func startWhenPortAvailable(host: String, port: Int) { portWaiter.startWhenPortAvailable(host: host, port: port) }
    nonisolated static func isListenPortAvailable(host: String, port: Int) -> Bool {
        PortWaiter.isListenPortAvailable(host: host, port: port)
    }

    // MARK: - Logging

    func setPerformanceMonitoring(_ enabled: Bool) { logSession.setPerformanceMonitoring(enabled) }
    func applyPerformanceBatch(_ batch: ServerLogBatch, monitorID: UUID) { logSession.applyPerformanceBatch(batch, monitorID: monitorID) }
    func clearLogCollection(logPath: String) throws { try logSession.clearLogCollection(logPath: logPath) }
    func lastLogReason(logPath: String) -> String { logSession.lastLogReason(logPath: logPath) }
    func launchFailureReason(logPath: String) -> String { logSession.launchFailureReason(logPath: logPath) }
    nonisolated static func rotateLog(at path: String, maximumBytes: Int, activeFileDescriptor: Int32) throws {
        try ServerLogSession.rotateLog(at: path, maximumBytes: maximumBytes, activeFileDescriptor: activeFileDescriptor)
    }

    // MARK: - Cleanup

    /// Release all resources associated with the current process (file handles,
    /// timers, process reference). Called after launch failure or when the
    /// orchestrator decides not to restart.
    func cleanup() {
        dispatchPrecondition(condition: .onQueue(.main))
        logSession.stopLogMonitoring()
        process = nil
        currentRunID = nil
        logFileHandle?.closeFile()
        logFileHandle = nil
        portWaiter.cancelPortWait()
        forceKillTimer?.cancel(); forceKillTimer = nil
    }

    // MARK: - Process state queries

    /// Whether the child process exists and is running.
    /// Includes an exited child whose cleanup callback is still queued.
    var ownedPID: Int32? { process?.processIdentifier }

    var hasPendingRun: Bool { currentRunID != nil }

    var isProcessRunning: Bool {
        guard let proc = process else { return false }
        return proc.isRunning
    }

    /// The process identifier of the currently running server, if any.
    var currentPID: Int32? {
        guard let proc = process, proc.isRunning else { return nil }
        return proc.processIdentifier
    }

    // MARK: - Utilities

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static func timestamp() -> String {
        dateFormatter.string(from: Date())
    }
}
