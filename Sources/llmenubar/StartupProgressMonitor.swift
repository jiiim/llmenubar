// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation

/// Run-scoped sampling. Slow file/cache work never blocks the main actor.
@MainActor
final class StartupProgressMonitor {
    typealias Sampler = @Sendable (ServerConfiguration.Config, Date) async -> StartupPhase
    private let sampler: Sampler
    init(sampler: @escaping Sampler = { config, began in
        await Task.detached(priority: .utility) { StartupProgressMonitor.sample(configuration: config, began: began) }.value
    }) { self.sampler = sampler }
    isolated deinit { task?.cancel() }
    var onChange: ((StartupPhase) -> Void)?
    private var task: Task<Void, Never>?
    private var generation = 0
    func start(configuration: ServerConfiguration.Config) {
        stop()
        let issued = generation
        let began = Date()
        let sampler = sampler
        task = Task { [weak self] in
            while !Task.isCancelled {
                let phase = await sampler(configuration, began)
                guard !Task.isCancelled, self?.generation == issued else { return }
                self?.onChange?(phase)
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
    func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
        onChange?(.starting)
    }
    nonisolated static func sample(configuration: ServerConfiguration.Config, began: Date) -> StartupPhase {
        var phase = StartupPhase.detect(logTail: ServerLogDiagnostics.logTail(logPath: configuration.logPath))
        if var download = phase.download, let repository = download.repository {
            let location = ModelCache.effectiveLocation(setting: configuration.modelCacheDirectory,
                                                        environmentText: configuration.environment)
            let bytes = ModelCache.receivedBytes(repository: repository, in: location.path, since: began)
            download.receivedBytes = bytes > 0 ? bytes : nil
            phase = .downloading(download)
        }
        return phase
    }
}
