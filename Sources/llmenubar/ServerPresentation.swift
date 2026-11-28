// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation

@MainActor
final class ServerPresentation {
    var onPerformance: ((ServerPerformance) -> Void)?
    var onWeights: ((Bool) -> Void)?
    var onRates: ((ServerRates) -> Void)?
    /// Everything shown belongs to one run. A change of status ends the run
    /// being shown: the unloaded flag, the speed and the rates go, and any
    /// display work still scheduled is cancelled so it cannot publish into the
    /// next one.
    var status: ServerStatus = .stopped {
        didSet {
            guard oldValue != status else { return }
            weightsAreReleased = false
            rates = ServerRates()
            apply(performancePolicy.reset(now: Date()))
        }
    }
    private var performance: ServerPerformance = .idle { didSet { onPerformance?(performance) } }
    private var weightsAreReleased = false { didSet { onWeights?(weightsAreReleased) } }
    private var rates = ServerRates() { didSet { onRates?(rates) } }
    var performancePolicy = PerformanceDisplayPolicy()
    private var publishGeneration = 0
    private var performancePublishWorkItem: DispatchWorkItem?
    // MARK: - Performance display

    /// PerformanceDisplayPolicy decides *when* the speed may change; this side
    /// owns the clock, the timer, and the published value. It is followed
    /// whether or not the menu bar shows it, so that turning the speed on shows
    /// what it would have shown all along.
    func receivePerformance(_ update: ServerPerformance) {
        guard case .running = status else { return }
        apply(performancePolicy.receive(update, now: Date()))
    }

    /// The status menu keeps the latest rates until the run ends, through an
    /// unload too.
    func receiveRates(_ newer: ServerRates) {
        guard case .running = status else { return }
        var merged = rates
        merged.merge(newer)
        if rates != merged { rates = merged }
    }

    /// An unloaded model has no current speed: the display goes to `----`.
    func receiveWeights(_ event: WeightsEvent) {
        guard case .running = status else { return }
        let released = event == .released
        if released {
            apply(performancePolicy.reset(now: Date()))
        }
        if weightsAreReleased != released { weightsAreReleased = released }
    }

    func apply(_ effects: [PerformanceDisplayPolicy.Effect]) {
        for effect in effects {
            switch effect {
            case .display(let update):
                performance = update

            case .cancelPublish:
                publishGeneration &+= 1
                performancePublishWorkItem?.cancel()
                performancePublishWorkItem = nil

            case .schedulePublish(let delay):
                publishGeneration &+= 1
                let issued = publishGeneration
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.publishGeneration == issued else { return }
                    self.performancePublishWorkItem = nil
                    self.apply(self.performancePolicy.publishTimerFired(now: Date()))
                }
                performancePublishWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
    }
}
