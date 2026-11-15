// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation

@MainActor
final class ServerPowerController {
    // ASCII only: pmset mangles non-ASCII in assertion names, and the name
    // exists to be read there.
    private let idleSleepAssertion = IdleSleepAssertion(
        name: "LLMenuBar: the engine is running"
    )
    private let externalPower = ExternalPowerMonitor()

    var onChange: ((KeepAwakeState) -> Void)?
    private var enabled = false
    private var status: ServerStatus = .stopped
    init() {
        externalPower.onChange = { [weak self] in self?.reconcile() }
        externalPower.start()
    }
    isolated deinit { externalPower.stop(); idleSleepAssertion.release() }
    func update(enabled: Bool, status: ServerStatus) {
        self.enabled = enabled
        self.status = status
        reconcile()
    }
    private func reconcile() {
        let state = KeepAwakePolicy.state(preferenceEnabled: enabled, status: status,
                                         onExternalPower: externalPower.isOnExternalPower)
        if state == .active { idleSleepAssertion.hold() } else { idleSleepAssertion.release() }
        onChange?(state)
    }
}
