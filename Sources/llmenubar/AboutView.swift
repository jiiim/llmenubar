// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

/// Custom About window modeled after the standard "About Finder" panel:
/// fixed size, no minimize/zoom, centered icon and text, small system fonts.
struct AboutView: View {
    private var version: String {
        let release = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "dev"
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !build.isEmpty
        else { return release }
        return "\(release) (\(build))"
    }

    private func noticeButton(_ title: String, resource: String) -> some View {
        let url = Bundle.main.url(forResource: resource, withExtension: "txt")
        return Button(title) {
            if let url { NSWorkspace.shared.open(url) }
        }
        .buttonStyle(.link)
        .font(.system(size: 10))
        .disabled(url == nil)
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text("LLMenuBar")
                .font(.system(size: 13, weight: .bold))

            Text("A menu bar control for\nyour local inference engine")
                .font(.system(size: 11))

            Text("LLMenuBar version \(version)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text("© James Martin")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            // The MIT notice and the trademark notice shipped inside the app. A
            // build run from source has no bundle to find them in.
            HStack(spacing: 12) {
                noticeButton("License", resource: "LICENSE")
                noticeButton("Trademarks", resource: "TRADEMARKS")
            }
        }
        .multilineTextAlignment(.center)
        .padding(20)
        .frame(width: 270)
        .fixedSize()
    }
}

/// Hosts the singleton SwiftUI About view in a standard AppKit window. This is
/// used because macOS 26's NSHostingSceneRepresentation does not present a
/// `Window` scene through `openWindow(id:)`.
@MainActor
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    init() {
        let content = NSHostingController(rootView: AboutView())
        let window = NSWindow(contentViewController: content)
        window.styleMask = [.titled, .closable]
        // Titled but not shown, matching the standard About panel. The title
        // is still what the Window menu lists this window under.
        window.title = "About LLMenuBar"
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        content.view.layoutSubtreeIfNeeded()
        window.setContentSize(content.view.fittingSize)

        super.init(window: window)
        window.delegate = self
        park(window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            park(window)
        }
    }

    private func park(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let frame = window.frame
        window.setFrameOrigin(NSPoint(
            x: area.midX - frame.width / 2,
            y: area.maxY - area.height / 5 - frame.height
        ))
    }
}
