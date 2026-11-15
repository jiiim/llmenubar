// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation

/// Sole owner of lifecycle intent. Adapters execute effects and return events;
/// no process, clock, network, or presentation work runs inside this value.
struct ServerLifecycle {
    enum Next { case stop, restart, quit, failure(String) }
    enum Phase {
        case stopped, failed(String)
        case starting(UUID, ServerLaunchSource, Int32?)
        case running(UUID, Int32)
        case stopping(UUID, Next)
        case waiting(UUID)
    }
    enum Event {
        case start(UUID, ServerLaunchSource), stop, restart(UUID), quit
        case launched(UUID, Int32), launchFailed(UUID, String)
        case ready(UUID), unhealthy(UUID, String), exited(UUID, Bool, String)
        case portAvailable(UUID, UUID), stable(UUID)
    }
    enum Effect {
        case launch(UUID), terminate(UUID), waitForPort(UUID), poll(UUID)
        case stopMonitoring, armStability(UUID), completeQuit
        case launchFailure(String, ServerLaunchSource)
        case notification(String, String)
    }
    private(set) var phase: Phase = .stopped
    private(set) var quitting = false
    private(set) var restartAttempted = false
    var automaticRestart = true
    private var restartNotice: (String, String)?

    var runID: UUID? {
        switch phase {
        case .starting(let id, _, _), .running(let id, _), .stopping(let id, _), .waiting(let id): return id
        case .stopped, .failed: return nil
        }
    }
    var status: ServerStatus {
        switch phase {
        case .stopped: return .stopped
        case .failed(let message): return .error(message)
        case .starting(_, let source, _): return source == .manual ? .starting : .restarting
        case .running(_, let pid): return .running(pid: pid)
        case .waiting: return .restarting
        case .stopping(_, let next):
            if case .restart = next { return .restarting }
            return .stopping
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .start(let id, let source):
            guard !quitting else { return [] }
            switch phase {
            case .stopped, .failed:
                if source == .manual { restartAttempted = false }
                phase = .starting(id, source, nil)
                return [.launch(id)]
            default: return []
            }
        case .restart(let id):
            guard !quitting else { return [] }
            switch phase {
            case .stopped, .failed: return handle(.start(id, .restart))
            case .starting(let run, _, _), .running(let run, _):
                phase = .stopping(run, .restart)
                return [.stopMonitoring, .terminate(run)]
            default: return []
            }
        case .stop, .quit:
            if case .quit = event { quitting = true }
            restartNotice = nil
            switch phase {
            case .starting(let id, _, _), .running(let id, _), .stopping(let id, _):
                phase = .stopping(id, quitting ? .quit : .stop)
                return [.stopMonitoring, .terminate(id)]
            default:
                phase = .stopped
                return [.stopMonitoring] + (quitting ? [.completeQuit] : [])
            }
        case .launched(let id, let pid):
            guard case .starting(id, let source, nil) = phase, runID == id else { return [] }
            phase = .starting(id, source, pid)
            return [.poll(id)]
        case .launchFailed(let id, let message):
            guard runID == id, case .starting(_, let source, _) = phase else { return [] }
            phase = .failed(message)
            restartNotice = nil
            return [.stopMonitoring, .launchFailure(message, source)]
        case .ready(let id):
            guard runID == id, case .starting(_, _, let pid?) = phase else { return [] }
            phase = .running(id, pid)
            var effects: [Effect] = [.armStability(id)]
            if let notice = restartNotice { effects.append(.notification(notice.0, notice.1)) }
            restartNotice = nil
            return effects
        case .unhealthy(let id, let reason):
            guard runID == id, case .running = phase else { return [] }
            phase = .stopping(id, .failure(reason))
            return [.stopMonitoring, .terminate(id)]
        case .exited(let id, let clean, let detail):
            guard runID == id else { return [] }
            switch phase {
            case .stopping(_, .quit):
                phase = .stopped
                return [.stopMonitoring, .completeQuit]
            case .stopping(_, .stop):
                phase = .stopped
                return [.stopMonitoring]
            case .stopping(_, .restart):
                phase = .waiting(id)
                return [.stopMonitoring, .waitForPort(id)]
            case .starting(_, let source, _):
                let reason = detail.isEmpty ? "The engine exited during startup" : detail
                phase = .failed(reason)
                restartNotice = nil
                return [.stopMonitoring, .launchFailure(reason, source)]
            case .stopping(_, .failure(let reason)):
                return recover(id, reason: reason, title: "The engine was unresponsive",
                               completion: "It stopped answering health checks and has been restarted.", stoppedTitle: "The engine stopped")
            case .running:
                let reason = "The engine exited unexpectedly" + (detail.isEmpty ? "" : " — " + detail)
                return recover(id, reason: reason,
                               title: clean ? "The engine stopped unexpectedly" : "The engine crashed",
                               completion: clean ? "It was terminated from outside the app and has been restarted." : "It exited unexpectedly and has been restarted.")
            default: return []
            }
        case .portAvailable(let id, let replacement):
            guard runID == id, case .waiting = phase, !quitting else { return [] }
            phase = .starting(replacement, .restart, nil)
            return [.launch(replacement)]
        case .stable(let id):
            guard runID == id, case .running = phase else { return [] }
            restartAttempted = false
            return []
        }
    }

    private mutating func recover(_ id: UUID, reason: String, title: String, completion: String, stoppedTitle: String? = nil) -> [Effect] {
        if AutoRestartPolicy.decision(preferenceEnabled: automaticRestart, restartable: true,
                                      attemptedThisEpisode: restartAttempted) == .restart {
            restartAttempted = true
            restartNotice = (title, completion)
            phase = .waiting(id)
            return [.stopMonitoring, .waitForPort(id)]
        }
        phase = .failed(reason)
        restartNotice = nil
        let suffix = automaticRestart ? "Automatic restart is not repeating." : "Automatic restart is off."
        let punctuation = reason.last.map { ".!?".contains($0) } == true ? " " : ". "
        return [.stopMonitoring, .notification(stoppedTitle ?? title, reason + punctuation + suffix)]
    }
}
