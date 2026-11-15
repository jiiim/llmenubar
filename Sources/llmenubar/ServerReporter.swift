// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation

import UserNotifications
import os.log

@MainActor
final class ServerReporter {
    typealias Sink = (String, String) -> Void
    let notificationSink: Sink?
    private let log = OSLog(subsystem: "com.jiiim.llmenubar", category: "notifications")
    init(sink: Sink?) { notificationSink = sink }
    /// Post a macOS notification so the user is informed of server state changes
    /// even when not watching the menubar icon.
    func postNotification(
        title: String,
        body: String,
        categoryIdentifier: String? = nil,
        userInfo: [String: String] = [:]
    ) {
        if let notificationSink {
            notificationSink(title, body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let categoryIdentifier {
            content.categoryIdentifier = categoryIdentifier
        }
        content.userInfo = userInfo
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                os_log(.error, log: self.log, "unable to schedule notification: %{public}@",
                       error.localizedDescription)
            }
        }
    }
}
