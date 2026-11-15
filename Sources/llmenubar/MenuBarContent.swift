// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import AppKit
import Combine

// MARK: - Status presentation

extension ServerStatus {
    /// States where the server is mid-transition — the menubar glyph blinks here.
    var isTransitional: Bool {
        switch self {
        case .starting, .stopping, .restarting: return true
        case .stopped, .running, .error: return false
        }
    }

    /// Menubar logo when not transitioning: drawn normally = on, dimmed = off.
    /// While the server starts, restarts or stops, the logo alternates between
    /// the two.
    var steadyGlyphIsDimmed: Bool {
        if case .running = self { return false }
        return true
    }

    /// Human-readable run state shown in the menu.
    var menuText: String {
        switch self {
        case .stopped:          return "Stopped"
        case .starting:         return "Starting…"
        case .restarting:       return "Restarting…"
        case .running(let pid): return "Running (PID \(pid))"
        case .stopping:         return "Stopping…"
        case .error(let msg):   return "Error: \(msg)"
        }
    }

    /// Title of the start/stop/cancel action item.
    var actionTitle: String {
        switch self {
        case .stopped, .error:    return "Start Server"
        case .starting:           return "Cancel Start"
        case .restarting:         return "Cancel Restart"
        case .running, .stopping: return "Stop Server"
        }
    }

    /// Whether the matching Server menu command applies in this state.
    var canStart: Bool {
        switch self {
        case .stopped, .error: return true
        case .starting, .running, .restarting, .stopping: return false
        }
    }

    /// Start and restart are cancellable through `stop()`, so they count as
    /// stoppable; a shutdown already under way does not.
    var canStop: Bool {
        switch self {
        case .starting, .running, .restarting: return true
        case .stopped, .stopping, .error: return false
        }
    }

    /// Restart is offered only for a live server. From any other state it
    /// would be a start, which the Start item already covers.
    var canRestart: Bool {
        if case .running = self { return true }
        return false
    }
}

// MARK: - Menu-bar item

/// Where the status item first appears.
///
/// With no saved position, macOS puts a new item at the left end of the status
/// area. On a narrow or crowded menu bar that is under the active app's menus,
/// so a first launch can show no icon at all. The saved position is the
/// distance from the right edge of the menu bar, which the user changes by
/// dragging the item with Command held; an item given a small distance starts
/// beside the clock, where it is always visible.
/// How the status item looks while the server is not running.
enum StatusItemAppearance {
    /// How opaque the logo is while the server is stopped, from 0 (gone) to 1
    /// (as when running). The button's own disabled look has no setting; an
    /// alpha does, so the amount of dimming can be chosen.
    static let dimmedAlpha: CGFloat = 0.6
}

enum StatusItemPlacement {
    static let autosaveName = "LLMenuBar"
    static let initialDistanceFromRight: CGFloat = 150

    static var defaultsKey: String { "NSStatusItem Preferred Position \(autosaveName)" }

    /// Give the item a starting position unless it has one. Returns whether it
    /// did. Must run before the item's `autosaveName` is set, which is when the
    /// saved position is read.
    @discardableResult
    static func seedInitialPosition(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: defaultsKey) == nil else { return false }
        defaults.set(Double(initialDistanceFromRight), forKey: defaultsKey)
        return true
    }
}

/// Owns the native NSStatusItem and its menu.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let server: ServerManager
    private let openSettings: (ServerSettingsDestination?) -> Void
    private let openAbout: () -> Void
    private let requestQuit: () -> Void
    private let statusItem: NSStatusItem
    private var cancellables = Set<AnyCancellable>()
    private var blinkTimer: AnyCancellable?
    private var activityRefreshTimer: AnyCancellable?
    private var blinkOn = false
    private var menuIsOpen = false
    private var rendered: RenderedStatusItem?
    private var renderedStatusInformation: String?

    /// Names the server and the address it is configured to listen at, so
    /// the address clients need is in the menu. "At", not "on": the line is
    /// there while the server is stopped too.
    private let serverItem = NSMenuItem(title: "Engine", action: nil, keyEquivalent: "")
    /// Replaces the line while Option is held, the way macOS menus offer an
    /// alternate action. It copies the address, and works while the server is
    /// stopped too.
    private let copyAddressItem = NSMenuItem(title: "Copy Address", action: nil, keyEquivalent: "")
    private var chatPageURL: URL?
    private let statusTextItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let lastActivityItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let serverActionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "s")
    /// Names the model the app is configured to run and opens the Model pane;
    /// switching models happens there, where the file is checked before it is
    /// applied.
    private let modelItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// The names the API accepts for the model, copied from a submenu.
    private let modelNamesItem = NSMenuItem(title: "API Model Names", action: nil, keyEquivalent: "")
    private let modelNamesMenu: NSMenu = {
        let menu = NSMenu(title: "API Model Names")
        menu.autoenablesItems = false
        return menu
    }()
    /// Between the actions and the model, hidden with the model.
    private let modelSeparator = NSMenuItem.separator()
    private let speedItem = NSMenuItem(
        title: "Show Speed in Menu Bar",
        action: nil,
        keyEquivalent: ""
    )
    /// The addresses and key a client needs, copied from a submenu.
    private let apiInformationItem = NSMenuItem(title: "API Access", action: nil, keyEquivalent: "")
    private let copyAnthropicItem = NSMenuItem(title: "Copy Anthropic API Address", action: nil, keyEquivalent: "")
    private let copyOpenAIItem = NSMenuItem(title: "Copy OpenAI API Address", action: nil, keyEquivalent: "")
    private let copyKeyItem = NSMenuItem(title: APIInformationMenu.keyTitle, action: nil, keyEquivalent: "")
    private var apiInformation: APIInformationMenu?
    private let apiMenu = NSMenu(title: "API Information")
    /// The addresses for other devices, which exist only while Splash listens on
    /// every interface. Rebuilt with the menu.
    private var otherDeviceItems: [NSMenuItem] = []
    private let keepAwakeItem = NSMenuItem(
        title: "Keep Mac Awake While Server Runs",
        action: nil,
        keyEquivalent: ""
    )

    /// What the status button was last given. Every assignment to a status
    /// item's title relayouts the menu bar, and most updates that reach here
    /// carry nothing new — a rate that renders to the same four columns, or a
    /// status change while speeds are hidden.
    private struct RenderedStatusItem: Equatable {
        let dimmed: Bool
        let performance: ServerPerformance.DisplayIdentity?
    }

    init(
        server: ServerManager,
        openSettings: @escaping (ServerSettingsDestination?) -> Void,
        openAbout: @escaping () -> Void,
        requestQuit: @escaping () -> Void
    ) {
        self.server = server
        self.openSettings = openSettings
        self.openAbout = openAbout
        self.requestQuit = requestQuit
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        StatusItemPlacement.seedInitialPosition()
        statusItem.autosaveName = StatusItemPlacement.autosaveName
        super.init()

        statusItem.menu = makeMenu()
        observeServer()
        updateBlinkTimer()
        updateStatusButton()
        updateStatusInformation()
        refreshMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        refreshMenu()
        // The relative time would otherwise freeze at whatever it read when the
        // menu opened, so keep recomputing it while the menu is up.
        activityRefreshTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateLastActivityItem()
            }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        activityRefreshTimer?.cancel()
        activityRefreshTimer = nil
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        serverItem.target = self
        serverItem.action = #selector(openChatPage)
        copyAddressItem.target = self
        copyAddressItem.action = #selector(copyAddress)
        copyAddressItem.isAlternate = true
        copyAddressItem.keyEquivalentModifierMask = .option
        copyAddressItem.isEnabled = true
        statusTextItem.isEnabled = false
        lastActivityItem.isEnabled = false
        serverActionItem.target = self
        serverActionItem.action = #selector(toggleServer)
        serverActionItem.keyEquivalentModifierMask = .command
        serverActionItem.isEnabled = true
        modelItem.target = self
        modelItem.action = #selector(showModelSettings)
        modelItem.isEnabled = true
        modelNamesItem.submenu = modelNamesMenu
        modelNamesItem.isEnabled = true
        speedItem.target = self
        speedItem.action = #selector(toggleSpeedDisplay)
        speedItem.isEnabled = true
        keepAwakeItem.target = self
        keepAwakeItem.action = #selector(toggleKeepAwake)
        keepAwakeItem.isEnabled = true

        apiMenu.autoenablesItems = false
        for (item, action) in [
            (copyAnthropicItem, #selector(copyAnthropicAddress)),
            (copyOpenAIItem, #selector(copyOpenAIAddress)),
            (copyKeyItem, #selector(copyAPIKey)),
        ] {
            item.target = self
            item.action = action
            apiMenu.addItem(item)
        }
        apiMenu.addItem(.separator())
        apiMenu.addItem(item("Configure API…", action: #selector(showAPISettings)))
        apiInformationItem.submenu = apiMenu
        apiInformationItem.isEnabled = true

        menu.addItem(serverItem)
        menu.addItem(copyAddressItem)
        menu.addItem(statusTextItem)
        menu.addItem(lastActivityItem)
        menu.addItem(.separator())
        // Actions, the model, what clients copy, the options that stay on, and
        // then the app's own items. This is a menu bar menu, not an app menu:
        // Settings comes first, About is the least needed, and Quit stands
        // alone at the bottom behind a rule so it is not clicked by accident.
        menu.addItem(serverActionItem)
        menu.addItem(item("Open Log in Console", action: #selector(openLog)))
        menu.addItem(modelSeparator)
        menu.addItem(modelItem)
        menu.addItem(.separator())
        menu.addItem(apiInformationItem)
        menu.addItem(modelNamesItem)
        menu.addItem(.separator())
        menu.addItem(speedItem)
        menu.addItem(keepAwakeItem)
        menu.addItem(.separator())
        menu.addItem(item("Settings…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(item("About LLMenuBar", action: #selector(showAbout)))
        menu.addItem(.separator())
        menu.addItem(item("Quit LLMenuBar", action: #selector(quit), keyEquivalent: "q"))
        return menu
    }

    private func item(
        _ title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.keyEquivalentModifierMask = .command
        item.isEnabled = true
        return item
    }

    /// Observe each input on the narrowest update path it needs. In particular,
    /// throughput records redraw only the visible title: they do not rewrite the
    /// status tooltip, the VoiceOver label, or the open menu.
    ///
    /// Delivery is hopped to the main queue because `@Published` publishes in
    /// `willSet`: a subscriber that runs synchronously still reads the previous
    /// value off the property.
    private func observeServer() {
        server.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                updateBlinkTimer()
                updateStatusButton()
                updateStatusInformation()
                if menuIsOpen { refreshMenu() }
            }
            .store(in: &cancellables)

        server.$weightsAreReleased
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                updateStatusInformation()
                if menuIsOpen { refreshMenu() }
            }
            .store(in: &cancellables)

        server.$startupPhase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                updateStatusInformation()
                if menuIsOpen { refreshMenu() }
            }
            .store(in: &cancellables)

        server.$performance
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusButton()
            }
            .store(in: &cancellables)

        server.$showsPerformanceInMenuBar
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                updateStatusButton()
                if menuIsOpen { refreshMenu() }
            }
            .store(in: &cancellables)

        Publishers.Merge(
            server.$keepsAwakeWhileRunning.map { _ in () },
            server.$keepAwakeState.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            guard let self else { return }
            if menuIsOpen { refreshMenu() }
        }
        .store(in: &cancellables)

        server.$activeModelInfo
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateModelItem()
            }
            .store(in: &cancellables)
    }

    /// The blink means something only mid-transition. Running it for the app's
    /// whole lifetime woke the main run loop twice a second with the server
    /// stopped and nothing to animate.
    private func updateBlinkTimer() {
        guard server.status.isTransitional else {
            blinkTimer = nil
            blinkOn = false
            return
        }
        guard blinkTimer == nil else { return }
        blinkTimer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                blinkOn.toggle()
                updateStatusButton()
            }
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        if server.isQuitting {
            button.image = nil
            // An image-only button draws no title, whatever it is given.
            button.imagePosition = .noImage
            button.title = "Stopping…"
            statusItem.length = NSStatusItem.variableLength
            return
        }
        let dimmed = server.status.isTransitional
            ? !blinkOn
            : server.status.steadyGlyphIsDimmed

        let current = RenderedStatusItem(
            dimmed: dimmed,
            performance: server.showsPerformanceInMenuBar
                ? server.performance.displayIdentity
                : nil
        )
        guard current != rendered else { return }
        rendered = current

        button.alignment = .center
        button.imagePosition = .imageOnly
        button.title = ""
        if server.showsPerformanceInMenuBar {
            // The logo and the rate are one image, so the item is exactly as
            // wide as they are and the digits sit in the middle of it.
            let image = StatusItemRenderer.image(rate: server.performance.menuBarRate)
            button.image = image
            statusItem.length = image.size.width + StatusItemRenderer.horizontalPadding
        } else {
            // Just the logo: the item is as wide as it is.
            button.image = LogoMark.menuBarImage
            statusItem.length = LogoMark.menuBarImage.size.width + StatusItemRenderer.horizontalPadding
        }
        // The logo is a template image, so it takes the menu bar's own color on
        // any wallpaper. Dimming it is an alpha, which keeps that and lets the
        // amount be chosen; the button still takes clicks.
        button.alphaValue = dimmed ? StatusItemAppearance.dimmedAlpha : 1
        button.lineBreakMode = .byClipping
    }

    /// Status information is intentionally independent of throughput. A speed
    /// update must not cause assistive technology or the tooltip to receive a
    /// stream of otherwise identical updates.
    private func updateStatusInformation() {
        guard let button = statusItem.button else { return }
        let information = "LLMenuBar — \(server.statusText)"
        guard information != renderedStatusInformation else { return }
        renderedStatusInformation = information
        button.setAccessibilityLabel(information)
        button.toolTip = information
    }

    private func refreshMenu() {
        let configuration = server.configurationSnapshot()
        let title = "splash at " + ListenAddress(configuration.host)
            .displayed(port: configuration.port)
        serverItem.title = title
        chatPageURL = SplashEndpoints(configuration).chatPage
        // The line opens the chat page, so it is a plain item only while there
        // is a page to open. Otherwise it is text, as it was before.
        serverItem.isEnabled = SplashEndpoints.opensChatPage(
            status: server.status,
            chatPageEnabled: configuration.chatPageEnabled
        )
        // Said under the line, as the model's source is under its own, so it
        // is plain that the line does more than name the address.
        serverItem.subtitle = serverItem.isEnabled ? APIInformationMenu.openChatSubtitle : nil
        let information = APIInformationMenu(configuration)
        apiInformation = information
        copyAnthropicItem.isEnabled = information.anthropic != nil
        copyOpenAIItem.isEnabled = information.openAI != nil
        refreshOtherDeviceItems(for: configuration)
        copyKeyItem.title = information.keyTitle
        copyKeyItem.isEnabled = information.keyIsAvailable
        copyAddressItem.isEnabled = chatPageURL != nil
        statusTextItem.title = "Status: \(server.statusText)"
        updateLastActivityItem()
        serverActionItem.title = server.status.actionTitle
        // A shutdown already under way has nothing left to toggle.
        serverActionItem.isEnabled = server.status.canStart || server.status.canStop
        speedItem.state = server.showsPerformanceInMenuBar ? .on : .off
        // The check mark is the preference. The subtitle is what it is doing
        // now, which differs whenever the Mac is on battery or nothing is
        // running — an item that claimed to be keeping the Mac awake while it
        // was not would be worse than no item at all.
        keepAwakeItem.state = server.keepsAwakeWhileRunning ? .on : .off
        keepAwakeItem.subtitle = server.keepAwakeState.menuSubtitle
        server.refreshActiveModelInfo()
        updateModelItem()
    }

    /// One row that answers "which model is this?" and points at the pane
    /// where it can be changed, and the submenu that copies the names the API
    /// accepts for it.
    private func updateModelItem() {
        let info = server.activeModelInfo
        let hasModel = !info.title.isEmpty
        modelItem.isHidden = !hasModel
        modelSeparator.isHidden = !hasModel
        modelNamesItem.isHidden = !hasModel
        guard hasModel else { return }
        modelItem.title = "Model: \(info.title)"
        modelItem.subtitle = info.subtitle
        modelItem.toolTip = info.toolTip

        modelNamesMenu.removeAllItems()
        for name in info.names {
            let item = NSMenuItem(title: "Copy \(name)", action: #selector(copyModelName(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.isEnabled = true
            modelNamesMenu.addItem(item)
        }
        modelNamesMenu.addItem(.separator())
        modelNamesMenu.addItem(item("Configure Model Names…", action: #selector(showAPISettings)))
    }

    @objc private func copyModelName(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(name, forType: .string)
    }

    private func updateLastActivityItem() {
        lastActivityItem.title = ServerActivityRecency.menuTitle(
            for: server.status,
            activity: server.lastServerUsageAt,
            now: Date()
        )
    }

    @objc private func openChatPage() {
        if let chatPageURL { AddressActions.open(chatPageURL) }
    }

    @objc private func copyAnthropicAddress() {
        if let url = apiInformation?.anthropic { AddressActions.copy(url) }
    }

    @objc private func copyOpenAIAddress() {
        if let url = apiInformation?.openAI { AddressActions.copy(url) }
    }

    /// With Splash on every interface the two addresses above work only on this
    /// Mac. Offer the same two under this Mac's network names, which is what a
    /// client on another device types.
    private func refreshOtherDeviceItems(for configuration: ServerConfiguration.Config) {
        for item in otherDeviceItems { apiMenu.removeItem(item) }
        otherDeviceItems = []
        let entries = OtherDeviceEndpoints.entries(
            host: configuration.host, port: configuration.port, names: LocalNetworkNames.current())
        guard !entries.isEmpty, let anchor = apiMenu.items.firstIndex(of: copyOpenAIItem) else { return }
        var items: [NSMenuItem] = []
        for entry in entries {
            for (title, url) in [("Copy OpenAI API Address (\(entry.label))", entry.openAI),
                                 ("Copy Anthropic API Address (\(entry.label))", entry.anthropic)] {
                let item = NSMenuItem(title: title, action: #selector(copyOtherDeviceAddress(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = url
                item.isEnabled = url != nil
                items.append(item)
            }
        }
        for (offset, item) in items.enumerated() { apiMenu.insertItem(item, at: anchor + 1 + offset) }
        otherDeviceItems = items
    }

    @objc private func copyOtherDeviceAddress(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { AddressActions.copy(url) }
    }

    @objc private func copyAPIKey() {
        let key = server.configurationSnapshot().apiKey
        if !key.isEmpty { AddressActions.copySecret(key) }
    }

    @objc private func copyAddress() {
        if let chatPageURL { AddressActions.copy(chatPageURL) }
    }

    /// Uses the same state rules as the Server menu's Start and Stop.
    @objc private func toggleServer() {
        if server.status.canStart {
            NSApp.activate()
            server.start()
        } else if server.status.canStop {
            server.stop()
        }
    }

    @objc private func openLog() {
        ServerLogActions.openInConsole(logPath: server.logPath)
    }

    @objc private func toggleSpeedDisplay() {
        server.setShowsPerformanceInMenuBar(!server.showsPerformanceInMenuBar)
    }

    @objc private func toggleKeepAwake() {
        server.setKeepsAwakeWhileRunning(!server.keepsAwakeWhileRunning)
    }

    @objc private func showSettings() {
        openSettings(nil)
    }

    @objc private func showModelSettings() {
        openSettings(.model)
    }

    @objc private func showAPISettings() {
        openSettings(.api)
    }

    @objc private func showAbout() {
        openAbout()
    }

    @objc private func quit() {
        // The delegate decides: it prompts while the server is active, and
        // falls through to the same stop-and-terminate otherwise.
        requestQuit()
    }
}

@MainActor
enum ServerLogActions {
    /// Open the server log in Console.app. If it doesn't exist yet, create it
    /// with the same owner-only permissions used by ProcessManager.
    static func openInConsole(logPath: String) {
        let path = (logPath as NSString).expandingTildeInPath
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            ServerLogSession.createOwnerOnlyDirectory(
                (path as NSString).deletingLastPathComponent, fm: fm)
            fm.createFile(atPath: path, contents: nil,
                          attributes: [.posixPermissions: 0o600])
        }
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path)],
            withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
            configuration: NSWorkspace.OpenConfiguration())
    }
}
