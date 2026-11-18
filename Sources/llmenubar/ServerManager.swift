// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Combine
import Foundation

// MARK: - ServerStatus

/// Represents the observable lifecycle state of the Splash process.
enum ServerStatus: Equatable {
    case stopped
    case starting
    case restarting
    case running(pid: Int32)
    case stopping
    case error(String)
}

extension ServerStatus {
    /// True while a server process is being brought up — either an initial
    /// start or a restart's relaunch — and we're awaiting its first health check.
    var isStartingUp: Bool {
        switch self {
        case .starting, .restarting: return true
        default: return false
        }
    }

    /// States in which a Splash process is live or on its way to being so.
    /// Model load and Metal residency happen during .starting, which is the
    /// longest unattended stretch of a run and precisely what keep-awake is for.
    var holdsServerProcess: Bool {
        switch self {
        case .starting, .restarting, .running, .stopping: return true
        case .stopped, .error: return false
        }
    }

    /// States where a quit interrupts work the user is waiting on: a model load
    /// in progress or a live server with connected clients. `.stopping` is the
    /// deliberate difference from `holdsServerProcess` — a shutdown is already
    /// under way, so a prompt would ask about work that is already ending.
    var requiresQuitConfirmation: Bool {
        switch self {
        case .starting, .restarting, .running: return true
        case .stopped, .stopping, .error: return false
        }
    }
}

/// UI facade and effect executor. ServerLifecycle alone owns transitions;
/// resource and presentation adapters do not decide whether to restart.
@MainActor
final class ServerManager: ObservableObject {
    // MARK: - Components

    let config: ServerConfiguration
    private let processManager: ProcessManager
    private let healthChecker: HealthChecker
    private let stabilityWindow: TimeInterval

    /// Injected by tests to count notifications instead of observing banners.
    typealias NotificationSink = (_ title: String, _ body: String) -> Void
    private let reporter: ServerReporter
    private let startupProgress = StartupProgressMonitor()

    @Published private(set) var isQuitting = false
    private var quitCompletions: [() -> Void] = []

    @Published private(set) var status: ServerStatus = .stopped {
        didSet { statusDidChange() }
    }
    /// What a starting engine is doing, read from its output while it starts.
    @Published private(set) var startupPhase: StartupPhase = .starting
    @Published private(set) var performance: ServerPerformance = .idle
    /// The engine gave the model's weights back after sitting idle; the next
    /// request brings them back. Only meaningful while running.
    @Published private(set) var weightsAreReleased = false
    @Published private(set) var showsPerformanceInMenuBar: Bool
    @Published private(set) var keepsAwakeWhileRunning: Bool
    @Published private(set) var confirmQuitWhileServerActive: Bool
    @Published private(set) var autoRestartServer: Bool
    @Published private(set) var recentSelections: RecentSelections
    @Published private(set) var keepAwakeState: KeepAwakeState = .off

    private let power = ServerPowerController()

    private let presentation = ServerPresentation()

    /// Receives one event for each failed launch attempt. The app layer uses
    /// manual events for a foreground alert; non-manual failures are notified
    /// by this manager because it already owns the notification path.
    var onLaunchFailure: ((ServerLaunchFailure) -> Void)?

    private var lifecycle = ServerLifecycle()
    private var eventQueue: [ServerLifecycle.Event] = []
    private var deliveringEvents = false
    private var runConfiguration: ServerConfiguration.Config?
    private var launchError = ""
    /// The status menu reads this instead of the configuration, so opening the
    /// menu never waits on the disk. `refreshActiveModelInfo` keeps it current.
    @Published private(set) var activeModelInfo = ActiveModelInfo.empty

    private var stabilityWorkItem: DispatchWorkItem?

    // MARK: - Init

    init(
        config: ServerConfiguration = ServerConfiguration(),
        processManager: ProcessManager = ProcessManager(),
        healthChecker: HealthChecker = HealthChecker(),
        stabilityWindow: TimeInterval = AutoRestartPolicy.stabilityWindow,
        notificationSink: NotificationSink? = nil
    ) {
        self.config = config
        self.processManager = processManager
        self.healthChecker = healthChecker
        self.stabilityWindow = stabilityWindow
        self.reporter = ServerReporter(sink: notificationSink)
        showsPerformanceInMenuBar = config.showsPerformanceInMenuBar
        keepsAwakeWhileRunning = config.keepsAwakeWhileRunning
        confirmQuitWhileServerActive = config.confirmQuitWhileServerActive
        autoRestartServer = config.autoRestartServer
        recentSelections = config.recentSelections
        startupProgress.onChange = { [weak self] in self?.startupPhase = $0 }
        presentation.showsPerformanceInMenuBar = showsPerformanceInMenuBar
        presentation.onPerformance = { [weak self] in self?.performance = $0 }
        presentation.onWeights = { [weak self] in self?.weightsAreReleased = $0 }
        wireCallbacks()
        processManager.setPerformanceMonitoring(showsPerformanceInMenuBar)
        power.onChange = { [weak self] in self?.keepAwakeState = $0 }
        refreshKeepAwake()
    }

    /// Establish the callback graph so each component reports back to us.
    private func wireCallbacks() {
        // ── ProcessManager → ServerManager ──

        processManager.onLaunchFailure = { [weak self] message in self?.launchError = message }
        processManager.onTerminationFailure = { [weak self] message in
            self?.postNotification(title: "The engine could not be stopped", body: message)
        }
        processManager.onPerformanceChange = { [weak self] in self?.presentation.receivePerformance($0) }
        processManager.onWeightsChange = { [weak self] in self?.presentation.receiveWeights($0) }

        // A long startup is legitimate — Splash can spend a long time on
        // model load and Metal residency — so this only informs the user, and
        // includes the last log line so a stuck startup is diagnosable without
        // opening Console. Nothing is terminated; polling continues.
        healthChecker.onStartupStalled = { [weak self] in
            guard let self = self else { return }
            let minutes = Int(self.healthChecker.stallAdvisoryInterval / 60)
            // A download has no deadline and can take hours; stopping it costs
            // the file being fetched, which starts over, so say so.
            if self.startupPhase.isDownloading {
                self.postNotification(
                    title: "The engine is still downloading the model",
                    body: "Still downloading after \(minutes) min. Large models can take hours. Stopping now discards the file in progress, which starts over next time."
                )
                return
            }
            let detail = self.lastLogReason()
            let body = detail.isEmpty
                ? "Still starting after \(minutes) min. This is normal for a large model; cancel from the menu if it looks stuck."
                : "Still starting after \(minutes) min — \(detail)"
            self.postNotification(title: "The engine is still starting", body: body)
        }

        healthChecker.isStartingUp = { [weak self] in
            self?.status.isStartingUp ?? false
        }

        healthChecker.isPaused = { [weak self] in
            self?.processManager.isRotatingLog ?? false
        }

        healthChecker.isRunning = { [weak self] in
            if case .running = self?.status { return true }
            return false
        }
    }

    // MARK: - Auto-restart

    /// The run state as the UI words it: a start that is downloading the model
    /// says so.
    var statusText: String {
        if status.isStartingUp, let text = startupPhase.statusText { return text }
        if case .running(let pid) = status, weightsAreReleased {
            return "Idle (PID \(pid)) (unloaded)"
        }
        return status.menuText
    }

    private func statusDidChange() {
        refreshKeepAwake()
        // A new run holds its weights; a stopped one has none to release.
        presentation.status = status
    }

    /// Completion events are queued until the current effect batch finishes.
    /// State is committed before any synchronous adapter callback can reenter.
    private func send(_ event: ServerLifecycle.Event) {
        eventQueue.append(event)
        guard !deliveringEvents else { return }
        deliveringEvents = true
        defer { deliveringEvents = false }
        while !eventQueue.isEmpty {
            lifecycle.automaticRestart = autoRestartServer
            let effects = lifecycle.handle(eventQueue.removeFirst())
            isQuitting = lifecycle.quitting
            status = lifecycle.status
            for effect in effects { execute(effect) }
        }
    }

    private func execute(_ effect: ServerLifecycle.Effect) {
        switch effect {
        case .launch(let id):
            let snapshot = config.snapshot()
            runConfiguration = snapshot
            startupProgress.stop()
            launchError = ""
            processManager.onTerminated = { [weak self] info in
                guard let self else { return }
                let reason = self.status.isStartingUp
                    ? self.processManager.launchFailureReason(logPath: snapshot.logPath)
                    : self.processManager.lastLogReason(logPath: snapshot.logPath)
                self.send(.exited(id, info.clean, reason))
            }
            guard let endpoints = processManager.launch(configuration: snapshot),
                  let pid = processManager.ownedPID else {
                send(.launchFailed(id, launchError.isEmpty ? "The engine exited during launch" : launchError))
                return
            }
            healthChecker.onHealthSuccess = { [weak self] in
                guard let self, self.processManager.isProcessRunning else { return }
                self.send(.ready(id))
            }
            healthChecker.onUnreachable = { [weak self] in self?.send(.unhealthy(id, $0)) }
            pendingEndpoints = endpoints
            send(.launched(id, pid))
        case .poll:
            if let snapshot = runConfiguration { startupProgress.start(configuration: snapshot) }
            switch pendingEndpoints {
            case .http(let ready, let liveness):
                healthChecker.startPolling(readyURL: ready, livenessURL: liveness)
            case .unixSocket(let path):
                healthChecker.startPolling(socketPath: path)
            case nil:
                break
            }
        case .terminate:
            processManager.terminate()
        case .waitForPort(let id):
            processManager.onPortAvailable = { [weak self] in self?.send(.portAvailable(id, UUID())) }
            let snapshot = config.snapshot()
            processManager.startWhenPortAvailable(host: snapshot.host, port: snapshot.port)
        case .stopMonitoring:
            startupProgress.stop()
            healthChecker.stop()
            processManager.cancelPortWait()
            stabilityWorkItem?.cancel()
            stabilityWorkItem = nil
        case .armStability(let id):
            startupProgress.stop()
            stabilityWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.send(.stable(id)) }
            stabilityWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + stabilityWindow, execute: work)
        case .completeQuit: finishQuit()
        case .launchFailure(let message, let source): reportLaunchFailure(message, source: source)
        case .notification(let title, let body): postNotification(title: title, body: body)
        }
    }

    private var pendingEndpoints: ProcessManager.HealthEndpoints?

    // MARK: - Configuration

    /// The server log path, for the menu-bar "Open Log in Console" action.
    /// While a run holds its log open, that run's file: Apply can change the
    /// configured path under a child still writing to the old one.
    var logPath: String {
        status.holdsServerProcess ? (runConfiguration?.logPath ?? config.logPath) : config.logPath
    }

    /// When the current run last served a request, read by the status menu
    /// when it opens. Not published: the menu recomputes on every refresh.
    var lastServerUsageAt: Date? { processManager.lastUsageAt }

    /// Apply the menu-bar display preference immediately without restarting the
    /// managed server. ProcessManager starts or stops its incremental log reader.
    func setShowsPerformanceInMenuBar(_ requested: Bool) {
        guard requested != showsPerformanceInMenuBar else { return }
        config.setShowsPerformanceInMenuBar(requested)
        showsPerformanceInMenuBar = requested
        presentation.showsPerformanceInMenuBar = requested
        if !requested {
            presentation.apply(presentation.performancePolicy.reset(now: Date()))
        }
        processManager.setPerformanceMonitoring(requested)
    }

    /// Apply the keep-awake preference immediately. Like the display preference
    /// above, it is an app-only setting: it does not alter Splash's command
    /// line and must not enter the Apply & Restart path.
    func setKeepsAwakeWhileRunning(_ requested: Bool) {
        guard requested != keepsAwakeWhileRunning else { return }
        config.setKeepsAwakeWhileRunning(requested)
        keepsAwakeWhileRunning = requested
        refreshKeepAwake()
    }

    /// Apply the quit-confirmation preference immediately. Like the keep-awake
    /// preference above, it is an app-only setting: it does not alter
    /// Splash's command line and must not enter the Apply & Restart path.
    func setConfirmQuitWhileServerActive(_ requested: Bool) {
        guard requested != confirmQuitWhileServerActive else { return }
        config.setConfirmQuitWhileServerActive(requested)
        confirmQuitWhileServerActive = requested
    }

    /// Apply the auto-restart preference immediately, on the same terms.
    func setAutoRestartServer(_ requested: Bool) {
        guard requested != autoRestartServer else { return }
        config.setAutoRestartServer(requested)
        autoRestartServer = requested
    }

    /// Forget one row's history in Settings' recent menus. Takes effect at
    /// once; no setting changes, so there is nothing to apply.
    func clearRecentSelections(field: RecentSelections.Field, family: String? = nil) {
        config.clearRecentSelections(field: field, family: family)
        recentSelections = config.recentSelections
    }

    /// What switching the draft `current` to a model of `family` puts back:
    /// the projector and draft that family was last applied with.
    func familyRestoration(for family: String, current: ServerConfiguration.Config) -> ModelFamilyMemory.Restoration? {
        config.familyRestoration(for: family, current: current)
    }

    /// Snapshot used by Settings to edit a draft without mutating the running
    /// process until the user applies it.
    func configurationSnapshot() -> ServerConfiguration.Config {
        config.snapshot()
    }

    /// Recompute the status menu's description of the configured model. For
    /// files on this Mac that is one stat of the path, so it runs on the main
    /// thread when the menu opens.
    func refreshActiveModelInfo() {
        let info = ActiveModelInfo.describing(config.snapshot())
        if activeModelInfo != info { activeModelInfo = info }
    }

    /// Apply the app's login-item setting without restarting Splash.
    func setLaunchAtLogin(_ requested: Bool) -> ServerConfiguration.LoginItemUpdate {
        objectWillChange.send()
        return config.setLaunchAtLogin(requested)
    }

    var needsInitialSetup: Bool {
        config.needsInitialSetup
    }

    func completeInitialSetup(
        splashPath: String,
        model: ServerConfiguration.InitialModel,
        modelCacheDirectory: String = "",
        huggingFaceToken: String = ""
    ) {
        config.completeInitialSetup(splashPath: splashPath, model: model, modelCacheDirectory: modelCacheDirectory,
                                    huggingFaceToken: huggingFaceToken)
        recentSelections = config.recentSelections
        refreshActiveModelInfo()
    }

    /// Clear the current server log and its rotated backup. ProcessManager
    /// truncates the active file in place, so this is safe while the server runs.
    func clearLog() throws {
        try processManager.clearLogCollection(logPath: logPath)
    }

    // MARK: - Public API

    /// Start the Splash process. Valid from .stopped or .error.
    /// A restart's relaunch arrives here as .restarting and keeps that label.
    func start() {
        start(source: .manual)
    }

    private func start(source: ServerLaunchSource) { send(.start(UUID(), source)) }

    func quit(completion: @escaping () -> Void) {
        quitCompletions.append(completion)
        send(.quit)
    }

    private func finishQuit() {
        let completions = quitCompletions
        quitCompletions.removeAll()
        for completion in completions { completion() }
    }

    func stop() { send(.stop) }
    func restart() { send(.restart(UUID())) }

    /// The result of applying a Settings draft, so the caller reports what
    /// actually happened rather than re-deriving it from `status`.
    struct ApplyResult {
        enum Kind {
            case invalid
            case applied
            case appliedAndRestarting
        }

        let kind: Kind
        /// Set when part of the configuration could not be put into effect.
        /// Today only launch-at-login, which the system can refuse outright or
        /// leave pending the user's approval.
        let warning: String?

        static let invalid = ApplyResult(kind: .invalid, warning: nil)
    }

    /// Apply a complete Settings snapshot. A live server is restarted so the
    /// new command line takes effect; a stopped server uses it on its next start.
    ///
    /// `derived` is what Settings read from the files the snapshot names, off
    /// the main thread. Passing it in reads no file at this point, so a file
    /// replaced between inspection and this call is validated against the older
    /// result; `ProcessManager.launch` re-checks the files before the child
    /// starts, which is where that is caught.
    ///
    /// `previous` must be the configuration that was applied when the draft
    /// was made, and the call is refused if it no longer is.
    @discardableResult
    func applyConfiguration(
        _ newConfig: ServerConfiguration.Config,
        derived: SplashDerivedState,
        previous: ServerConfiguration.Config
    ) -> ApplyResult {
        guard !isQuitting else { return .invalid }
        guard previous == config.snapshot() else { return .invalid }
        guard newConfig.normalized().validationErrors(derived: derived).isEmpty else {
            return .invalid
        }
        // Only a process that is actually alive needs restarting; .starting with
        // a dead process (a launch that never got off the ground) does not.
        let shouldRestart: Bool
        switch status {
        case .starting, .running, .restarting:
            shouldRestart = processManager.isProcessRunning
        case .stopped, .stopping, .error:
            shouldRestart = false
        }
        // ServerConfiguration is a separate reference object, so replacing its
        // value does not trigger this ObservableObject automatically. Publish
        // the mutation so Settings immediately recomputes its draft comparison.
        objectWillChange.send()
        config.replace(with: newConfig)
        let warning = config.save()
        // Only now, with the configuration applied and validated, does
        // anything enter the recent menus.
        config.recordAppliedSelections(previous: previous)
        recentSelections = config.recentSelections
        refreshActiveModelInfo()
        if shouldRestart {
            restart()
            return ApplyResult(kind: .appliedAndRestarting, warning: warning)
        }
        return ApplyResult(kind: .applied, warning: warning)
    }

    // MARK: - Keep awake

    /// Reconciles the assertion with the preference, the run state, and the
    /// power source. Called from `status`'s observer, the preference setter, and
    /// the power-source notification, so every input that can change the answer
    /// arrives here.
    private func refreshKeepAwake() {
        power.update(enabled: keepsAwakeWhileRunning, status: status)
    }

    // MARK: - Log tail (for crash/error descriptions)

    private func lastLogReason() -> String {
        processManager.lastLogReason(logPath: (runConfiguration ?? config.snapshot()).logPath)
    }

    // MARK: - Notifications

    private func reportLaunchFailure(_ message: String, source: ServerLaunchSource) {
        let failure = ServerLaunchFailure(message: message, source: source)
        onLaunchFailure?(failure)
        // A manual start has the user's attention already; the app layer shows
        // it a modal alert. Only an internal relaunch needs a notification.
        guard source == .restart else { return }
        postNotification(
            title: failure.notificationTitle,
            body: failure.notificationBody,
            categoryIdentifier: ServerNotification.launchFailureCategory,
            userInfo: [ServerNotification.settingsPaneKey: failure.settingsDestination.rawValue]
        )
    }

    private func postNotification(title: String, body: String, categoryIdentifier: String? = nil, userInfo: [String: String] = [:]) {
        reporter.postNotification(title: title, body: body, categoryIdentifier: categoryIdentifier, userInfo: userInfo)
    }
}
