// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import AppKit
import CoreServices.AE
import SwiftUI
import UserNotifications

private struct AppSettingsScene: Scene {
    let server: ServerManager

    var body: some Scene {
        Settings {
            SettingsView(server: server)
        }
        // The window's width is the view's fixed width; its height is set by
        // SettingsWindowFitter.
        .windowResizability(.contentSize)
    }
}

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
    NSMenuItemValidation, @preconcurrency UNUserNotificationCenterDelegate {
    /// macOS 26's scene representation API keeps the SwiftUI Settings scene
    /// available to this AppKit lifecycle.
    private lazy var settingsScene: NSHostingSceneRepresentation<AppSettingsScene> =
        NSHostingSceneRepresentation {
            AppSettingsScene(server: server)
        }

    /// Owned by the app delegate so normal termination can wait for child
    /// exit and cleanup before replying to AppKit.
    let server = ServerManager()

    private var statusBarController: StatusBarController?
    private var aboutWindowController: AboutWindowController?
    private var manualFailureAlertShowing = false
    private var quitConfirmationShowing = false
    private var terminationPending = false
    private var initialSetupWindowController: InitialSetupWindowController?
    private var initialSetupCompleted = false
    private var notificationAuthorizationRequested = false

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        MainMenu.install(on: NSApplication.shared)
        NSApp.addSceneRepresentation(settingsScene)
        SettingsNavigation.install { [weak self] in
            self?.settingsScene.environment.openSettings()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory: no dock icon, but the app can still bring its settings
        // window to the front. (LSUIElement in Info.plist also implies this.)
        // AppActivation flips this to .regular while a window is open so
        // Cmd-Tab can find the app, and back once the last window closes.
        NSApp.setActivationPolicy(.accessory)
        AppActivation.install()
        statusBarController = StatusBarController(
            server: server,
            openSettings: { destination in
                SettingsNavigation.open(destination)
                AppActivation.windowOpened()
            },
            openAbout: { [weak self] in self?.openAbout() },
            requestQuit: { [weak self] in self?.requestQuitFromStatusMenu() }
        )

        server.onLaunchFailure = { [weak self] failure in
            guard failure.source == .manual else { return }
            self?.presentManualLaunchFailure(failure)
        }

        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        let openSettings = UNNotificationAction(
            identifier: ServerNotification.openSettingsAction,
            title: "Open Settings",
            options: [.foreground]
        )
        notificationCenter.setNotificationCategories([
            UNNotificationCategory(
                identifier: ServerNotification.launchFailureCategory,
                actions: [openSettings],
                intentIdentifiers: [],
                options: []
            )
        ])

        if server.needsInitialSetup {
            DispatchQueue.main.async { [weak self] in
                self?.presentInitialSetup()
            }
        } else {
            requestNotificationAuthorization()
        }
    }

    @MainActor
    private func presentInitialSetup() {
        let controller = InitialSetupWindowController {
            [weak self] splashPath, model, modelCacheDirectory, huggingFaceToken in
            guard let self else { return }
            self.server.completeInitialSetup(
                splashPath: splashPath, model: model, modelCacheDirectory: modelCacheDirectory,
                huggingFaceToken: huggingFaceToken
            )
            self.initialSetupCompleted = true
            self.initialSetupWindowController?.close()
        }
        controller.window?.delegate = self
        initialSetupWindowController = controller
        controller.showWindow(nil)
        AppActivation.windowOpened()
    }

    private func requestNotificationAuthorization() {
        guard !notificationAuthorizationRequested else { return }
        notificationAuthorizationRequested = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === initialSetupWindowController?.window
        else { return }

        initialSetupWindowController = nil
        requestNotificationAuthorization()
        guard initialSetupCompleted else { return }
        initialSetupCompleted = false
        DispatchQueue.main.async { [weak self] in
            self?.openSettings(destination: .model)
        }
    }

    /// Show a launch failure the user is waiting on, as a modal alert.
    ///
    /// The staging below was arrived at empirically: earlier, simpler versions
    /// left the alert behind the previously-frontmost app, or showed it with no
    /// keyboard focus. What is *not* known is which individual steps are
    /// required — the deferrals, `unhide` before `activate`, and building the
    /// alert a turn before running it were never bisected against each other.
    /// Treat the sequence as one unit: if you simplify it, re-test surfacing
    /// with another app frontmost, not just from an idle desktop.
    ///
    /// The activation policy is deliberately left `.accessory` here. Unlike
    /// AppActivation.windowOpened, a modal alert fronts without promotion, and
    /// promoting would add a Dock icon for the alert's lifetime.
    ///
    /// Observed to work with a secure-keyboard-entry app frontmost. That was
    /// incidental rather than designed for, so it is a data point, not a
    /// guarantee this path maintains.
    private func presentManualLaunchFailure(_ failure: ServerLaunchFailure) {
        guard !manualFailureAlertShowing else { return }
        manualFailureAlertShowing = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Give the status-item menu a complete event-loop turn to finish
            // closing before preparing the alert window.
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                let alert = NSAlert()
                alert.messageText = "The engine could not start"
                alert.informativeText = failure.message
                alert.alertStyle = .critical
                alert.addButton(withTitle: "Open Settings")
                alert.addButton(withTitle: "Dismiss")
                alert.buttons.first?.keyEquivalent = "\r"
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }

                    NSApp.unhide(nil)
                    NSApp.activate()
                    alert.window.center()

                    if alert.runModal() == .alertFirstButtonReturn {
                        self.openSettings(destination: failure.settingsDestination)
                    }
                    self.manualFailureAlertShowing = false
                }
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        guard action == ServerNotification.openSettingsAction ||
              action == UNNotificationDefaultActionIdentifier,
              let rawDestination = response.notification.request.content
                .userInfo[ServerNotification.settingsPaneKey] as? String,
              let destination = ServerSettingsDestination(rawValue: rawDestination)
        else {
            completionHandler()
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.openSettings(destination: destination)
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // The app remains running as a menu-bar app while the server is live.
        // Explicitly request visible delivery when a failure is reported while
        // the app is considered foreground; otherwise macOS may deliver it
        // without showing a banner or playing its sound.
        completionHandler([.banner, .sound])
    }

    private func openSettings(destination: ServerSettingsDestination? = nil) {
        MainActor.assumeIsolated {
            SettingsNavigation.open(destination)
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                AppActivation.windowOpened()
            }
        }
    }

    // MainMenu dispatches to nil, so these are reached through the responder
    // chain: NSApp forwards unhandled application actions to its delegate.
    // The status item's menu reaches the same windows through the closures it
    // was constructed with.

    @objc func showAboutWindow(_ sender: Any?) {
        openAbout()
    }

    @objc func showSettingsWindow(_ sender: Any?) {
        openSettings()
    }

    // MARK: - Server commands

    @objc func startServer(_ sender: Any?) {
        server.start()
    }

    @objc func stopServer(_ sender: Any?) {
        server.stop()
    }

    @objc func restartServer(_ sender: Any?) {
        server.restart()
    }

    /// MainMenu dispatches to nil, so the app delegate is the responder that
    /// handles the Server menu, and this is what AppKit asks for its item
    /// states. Restart is offered only for a live server; from any other state
    /// it would be a start.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(startServer(_:)) {
            return server.status.canStart
        }
        if menuItem.action == #selector(stopServer(_:)) {
            return server.status.canStop
        }
        if menuItem.action == #selector(restartServer(_:)) {
            return server.status.canRestart
        }
        return true
    }

    private func openAbout() {
        if aboutWindowController == nil {
            aboutWindowController = AboutWindowController()
        }
        aboutWindowController?.showWindow(nil)
        AppActivation.windowOpened()
    }

    // MARK: - Quit

    /// Quit from the app menu or Cmd-Q. The status-item menu reaches the same
    /// decision through `requestQuitFromStatusMenu()`.
    @objc func requestQuit(_ sender: Any?) {
        requestQuit(afterMenuClose: false)
    }

    /// Quit from the status-item menu, whose menu is mid-close when its item
    /// fires. See `presentQuitConfirmation`.
    func requestQuitFromStatusMenu() {
        requestQuit(afterMenuClose: true)
    }

    private func requestQuit(afterMenuClose: Bool) {
        guard !terminationPending else { return }
        switch QuitConfirmation.decision(
            status: server.status,
            preferenceEnabled: server.confirmQuitWhileServerActive,
            promptIsPending: quitConfirmationShowing
        ) {
        case .proceed:
            NSApp.terminate(nil)

        case .cancelDuplicate:
            return

        case .prompt:
            quitConfirmationShowing = true
            let status = server.status
            let phase = server.startupPhase
            presentQuitConfirmation(for: status, phase: phase, afterMenuClose: afterMenuClose) {
                [weak self] confirmed in
                guard let self else { return }
                self.quitConfirmationShowing = false
                guard confirmed else { return }
                NSApp.terminate(nil)
            }
        }
    }

    /// Present the quit confirmation, then report whether it was confirmed.
    ///
    /// `afterMenuClose` reproduces the staging documented on
    /// `presentManualLaunchFailure`: the status-item menu needs a full
    /// event-loop turn to finish closing, and the alert is built a turn before
    /// it runs. Cmd-Q and Dock Quit arrive outside menu tracking and run the
    /// alert directly.
    ///
    /// Status can change while the alert is up. "Stop Server and Quit" stays
    /// correct for every state the predicate accepted, because `stop()` is
    /// safe whether or not a process is still live.
    private func presentQuitConfirmation(
        for status: ServerStatus,
        phase: StartupPhase,
        afterMenuClose: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        if afterMenuClose {
            DispatchQueue.main.async {
                DispatchQueue.main.async {
                    let alert = Self.makeQuitAlert(for: status, phase: phase)
                    // Not a main-queue block: the alert's modal session, and
                    // the `terminate` that follows a confirmation, wait in a
                    // nested run loop that cannot serve the queue from inside
                    // one. The engine's stop and exit are queue blocks, so a
                    // quit started from here never finished.
                    RunLoopScheduling.perform {
                        completion(Self.runQuitAlert(alert))
                    }
                }
            }
        } else {
            completion(Self.runQuitAlert(Self.makeQuitAlert(for: status, phase: phase)))
        }
    }

    private static func makeQuitAlert(for status: ServerStatus, phase: StartupPhase) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Quit LLMenuBar?"
        switch status {
        case .running:
            alert.informativeText =
                "The engine is running. Quitting stops it and interrupts any connected clients."
        case .starting where phase.isDownloading, .restarting where phase.isDownloading:
            // A download is the one start that costs something to cancel: the
            // file being fetched starts over, and it can be many gigabytes.
            alert.informativeText =
                "The engine is downloading the model. Quitting cancels the download, and the file in progress starts over next time."
        case .starting:
            alert.informativeText =
                "The engine is still starting. Quitting cancels the startup and the in-progress model load."
        case .restarting:
            alert.informativeText =
                "The engine is restarting. Quitting cancels the restart and stops the server."
        case .stopped, .stopping, .error:
            // The predicate excludes these states. The wording keeps the alert
            // from claiming work that is not happening if that ever changes.
            alert.informativeText = "Quitting stops LLMenuBar."
        }
        alert.addButton(withTitle: "Stop Server and Quit")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.keyEquivalent = "\r"
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        return alert
    }

    private static func runQuitAlert(_ alert: NSAlert) -> Bool {
        NSApp.unhide(nil)
        NSApp.activate()
        alert.window.center()
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Dock Quit

    /// Every normal quit waits for child cleanup. Only Dock requests add a
    /// confirmation here; in-app requests already confirmed, while scripted
    /// and cooperative session termination remain free of confirmation dialogs.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPending { return .terminateLater }
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let senderPID = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value,
              NSRunningApplication(processIdentifier: pid_t(senderPID))?.bundleIdentifier
                  == "com.apple.dock"
        else { return beginTermination() }

        switch QuitConfirmation.decision(
            status: server.status,
            preferenceEnabled: server.confirmQuitWhileServerActive,
            promptIsPending: quitConfirmationShowing
        ) {
        case .proceed:
            return beginTermination()

        case .cancelDuplicate:
            return .terminateCancel

        case .prompt:
            quitConfirmationShowing = true
            let status = server.status
            let phase = server.startupPhase
            // Strong self, and a reply on every path: a weak guard that failed
            // here would leave the app un-quittable. The alert runs a turn
            // later so this Apple event finishes dispatching first.
            DispatchQueue.main.async {
                let confirmed = Self.runQuitAlert(Self.makeQuitAlert(for: status, phase: phase))
                self.quitConfirmationShowing = false
                if confirmed {
                    self.terminationPending = true
                    self.server.quit { NSApp.reply(toApplicationShouldTerminate: true) }
                } else {
                    NSApp.reply(toApplicationShouldTerminate: false)
                }
            }
            return .terminateLater
        }
    }

    private func beginTermination() -> NSApplication.TerminateReply {
        terminationPending = true
        // Defer even an already-stopped completion until after terminateLater
        // has been returned to AppKit.
        DispatchQueue.main.async {
            self.server.quit { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }
}
