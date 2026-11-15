// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation

@MainActor
final class ServerPresentation {
    var onPerformance: ((ServerPerformance) -> Void)?
    var onWeights: ((Bool) -> Void)?
    /// Everything shown belongs to one run. A change of status ends the run
    /// being shown: the unloaded flag and the speed go, and any display work
    /// still scheduled is cancelled so it cannot publish into the next one.
    var status: ServerStatus = .stopped {
        didSet {
            guard oldValue != status else { return }
            weightsAreReleased = false
            apply(performancePolicy.reset(now: Date()))
        }
    }
    var showsPerformanceInMenuBar = false
    private var performance: ServerPerformance = .idle { didSet { onPerformance?(performance) } }
    private var weightsAreReleased = false { didSet { onWeights?(weightsAreReleased) } }
    var performancePolicy = PerformanceDisplayPolicy()
    private var publishGeneration = 0
    private var idleGeneration = 0
    private var performancePublishWorkItem: DispatchWorkItem?
    private var performanceIdleWorkItem: DispatchWorkItem?
    // MARK: - Performance display

    /// PerformanceDisplayPolicy decides *when* the menu bar may change; this
    /// side owns the clock, the two timers, and the published value.
    func receivePerformance(_ update: ServerPerformance) {
        guard showsPerformanceInMenuBar, case .running = status else { return }
        apply(performancePolicy.receive(update, now: Date()))
    }

    /// An unloaded model has no current speed: the display goes to `----` at
    /// once, without the hold a finished request gets.
    func receiveWeights(_ event: WeightsEvent) {
        guard case .running = status else { return }
        let released = event == .released
        if released, showsPerformanceInMenuBar {
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

            case .cancelIdle:
                idleGeneration &+= 1
                performanceIdleWorkItem?.cancel()
                performanceIdleWorkItem = nil

            case .scheduleIdle(let delay):
                idleGeneration &+= 1
                let issued = idleGeneration
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.idleGeneration == issued else { return }
                    self.performanceIdleWorkItem = nil
                    self.apply(self.performancePolicy.idleTimerFired(now: Date()))
                }
                performanceIdleWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
    }

}
