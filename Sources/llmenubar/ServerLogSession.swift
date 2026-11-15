// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation
import os.log

/// Owns log descriptors, rotation and incremental observation for a child.
/// Lifecycle decisions remain with ServerLifecycle.
@MainActor
final class ServerLogSession {
    var onPerformanceChange: ((ServerPerformance) -> Void)?
    var onWeightsChange: ((WeightsEvent) -> Void)?
    private(set) var lastUsageAt: Date?

    /// The child is suspended while the log is copied.
    var isRotating: Bool { logRotationID != nil }
    private weak var process: Process?
    private static let idleUsageReadInterval: TimeInterval = 1
    private let log = OSLog(subsystem: "com.jiiim.llmenubar", category: "log-session")
    var logFileHandle: FileHandle?
    private var logWriteSource: DispatchSourceFileSystemObject?
    private var logSizeCheckScheduled = false
    private var logMonitorID = UUID()
    /// Identifies the rotation that currently holds its child suspended. Each
    /// rotation mints its own, so a late completion from an earlier one cannot
    /// pass for the current one.
    private var logRotationID: UUID?
    private var activeLogPath: String?
    private var performanceMonitoringEnabled = false
    private let performanceReader = ServerPerformanceLogReader()
    private let performanceQueue = DispatchQueue(
        label: "com.jiiim.llmenubar.performance-log",
        qos: .utility
    )
    private let logRotationQueue = DispatchQueue(
        label: "com.jiiim.llmenubar.log-rotation",
        qos: .utility
    )
    /// Opens and owns the append descriptor for this run.
    func openLog(at path: String, maximumBytes: Int) -> FileHandle? {
        let fm = FileManager.default
        Self.createOwnerOnlyDirectory((path as NSString).deletingLastPathComponent, fm: fm)
        // An oversized log left by an older run becomes the backup before the
        // live descriptor opens. No child is running, so this is a rename, not
        // a copy: it takes no time however large the log is, and the main
        // actor never waits on it. Runtime monitoring handles later growth.
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int,
           size >= maximumBytes {
            if rename(path, path + ".1") == 0 {
                // Owner-only, whatever mode the old log had.
                chmod(path + ".1", 0o600)
            } else {
                // Not fatal — the launch proceeds against the oversized log
                // rather than refusing to start over a housekeeping failure.
                os_log(
                    .error,
                    log: log,
                    "startup log rotation failed: %{public}@",
                    String(cString: strerror(errno))
                )
            }
        }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else {
            return nil
        }
        // Bound locally as well as stored: the termination handler closes *this*
        // handle, never whatever `logFileHandle` happens to hold when it fires.
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        logFileHandle = handle
        // Enforce owner-only perms even if the file pre-existed with looser modes.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return handle
    }

    func startLogMonitoring(
        path: String,
        maximumBytes: Int,
        process monitoredProcess: Process,
        fileDescriptor: Int32
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        stopLogMonitoring()
        self.process = monitoredProcess
        // A new run starts unused, whatever the previous run's last record was;
        // the stop-time drain above has already accounted for those.
        lastUsageAt = nil
        let monitorID = UUID()
        logMonitorID = monitorID
        activeLogPath = path

        // The reader runs for the life of the server: request activity must not
        // depend on the menu-bar speed display being enabled.
        performanceQueue.async { [performanceReader] in
            performanceReader.start(path: path)
        }

        let monitorFileDescriptor = dup(fileDescriptor)
        guard monitorFileDescriptor >= 0 else {
            os_log(.error, log: log, "unable to monitor server log: %{public}@",
                   String(cString: strerror(errno)))
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: monitorFileDescriptor,
            eventMask: .write,
            queue: .main
        )
        source.setEventHandler { [weak self, weak monitoredProcess] in
            guard let self, let monitoredProcess else { return }
            self.readPerformanceUpdates(monitorID: monitorID)
            self.scheduleLogSizeCheck(
                monitorID: monitorID,
                path: path,
                maximumBytes: maximumBytes,
                process: monitoredProcess,
                fileDescriptor: fileDescriptor
            )
        }
        source.setCancelHandler {
            close(monitorFileDescriptor)
        }
        logWriteSource = source
        source.resume()
    }

    func stopLogMonitoring(completion: @escaping @MainActor @Sendable () -> Void = {}) {
        logWriteSource?.cancel()
        logWriteSource = nil
        logSizeCheckScheduled = false
        // A rotation still holding a live child suspended gives it back here;
        // a child that has exited needs nothing.
        if logRotationID != nil, let process, process.isRunning {
            cancelLogRotation(for: process)
        }
        logRotationID = nil
        activeLogPath = nil
        let id = logMonitorID
        performanceQueue.async { [performanceReader, weak self] in
            let batch = performanceReader.readAvailable()
            performanceReader.stop()
            let session = self
            DispatchQueue.main.async {
                if let self = session, self.logMonitorID == id {
                    self.applyPerformanceBatch(batch, monitorID: id)
                    self.logMonitorID = UUID()
                    if self.performanceMonitoringEnabled { self.onPerformanceChange?(.idle) }
                }
                completion()
            }
        }
    }

    /// Enable or disable forwarding parsed request records to the display. The
    /// reader itself runs for the life of the server: request activity must not
    /// depend on a display preference.
    func setPerformanceMonitoring(_ enabled: Bool) {
        guard enabled != performanceMonitoringEnabled else { return }
        performanceMonitoringEnabled = enabled
        guard enabled else {
            onPerformanceChange?(.idle)
            return
        }
        // Skip whatever accumulated while the display was off, so the next
        // record shown is current rather than a replay of idle history.
        guard let path = activeLogPath else { return }
        performanceQueue.async { [performanceReader] in
            performanceReader.start(path: path)
        }
    }

    private func readPerformanceUpdates(monitorID: UUID) {
        // With the display off, activity only needs a coarse timestamp, so the
        // read and its main hop are coalesced to this interval. The stop-time
        // drain still captures the final records exactly.
        if !performanceMonitoringEnabled, let lastUsageAt,
           Date().timeIntervalSince(lastUsageAt) < Self.idleUsageReadInterval {
            return
        }
        performanceQueue.async { [weak self, performanceReader] in
            let batch = performanceReader.readAvailable()
            guard !batch.isEmpty else { return }
            // Resolved here so the main hop captures an immutable binding
            // rather than this closure's mutable capture.
            let manager = self
            DispatchQueue.main.async {
                manager?.applyPerformanceBatch(batch, monitorID: monitorID)
            }
        }
    }

    /// Apply one batch of parsed records. Kept separate from the queue hop so a
    /// stale batch can be exercised directly: the monitor ID guard drops
    /// anything queued by a run that has since been replaced.
    func applyPerformanceBatch(_ batch: ServerLogBatch, monitorID: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard logMonitorID == monitorID else { return }
        if batch.sawRequestActivity {
            lastUsageAt = Date()
        }
        if let weights = batch.weights {
            onWeightsChange?(weights)
        }
        guard performanceMonitoringEnabled else { return }
        for update in batch.updates {
            onPerformanceChange?(update)
        }
    }

    private func rewindPerformanceReader() {
        performanceQueue.async { [performanceReader] in
            performanceReader.rewind()
        }
    }

    /// A server suspended for rotation must be resumed before termination. The
    /// background copy will see its invalidated rotation ID and discard its
    /// temporary file instead of touching a later process's log. This is the
    /// one resume for that suspension: `Process` counts them, and an extra
    /// `resume()` makes a later `suspend()` outlast its own `resume()`.
    func cancelLogRotation(for monitoredProcess: Process) {
        guard logRotationID != nil else { return }
        logRotationID = nil
        _ = monitoredProcess.resume()
    }

    /// Coalesce bursts so log-heavy servers cause at most one stat per second.
    private func scheduleLogSizeCheck(
        monitorID: UUID,
        path: String,
        maximumBytes: Int,
        process monitoredProcess: Process,
        fileDescriptor: Int32
    ) {
        guard monitorID == logMonitorID, !logSizeCheckScheduled else { return }
        logSizeCheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak monitoredProcess] in
            guard let self else { return }
            guard monitorID == self.logMonitorID else { return }
            self.logSizeCheckScheduled = false
            guard let monitoredProcess else { return }
            self.rotateLogIfNeeded(
                monitorID: monitorID,
                path: path,
                maximumBytes: maximumBytes,
                process: monitoredProcess,
                fileDescriptor: fileDescriptor
            )
        }
    }

    private func rotateLogIfNeeded(
        monitorID: UUID,
        path: String,
        maximumBytes: Int,
        process monitoredProcess: Process,
        fileDescriptor: Int32
    ) {
        guard monitorID == logMonitorID,
              logRotationID == nil,
              process === monitoredProcess,
              monitoredProcess.isRunning,
              let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size]
                as? NSNumber,
              size.uint64Value >= UInt64(maximumBytes)
        else { return }

        let rotationID = UUID()
        logRotationID = rotationID
        guard monitoredProcess.suspend() else {
            logRotationID = nil
            return
        }

        logRotationQueue.async { [weak self, weak monitoredProcess] in
            let result = Result {
                try Self.makeLogBackup(
                    at: path,
                    maximumBytes: maximumBytes
                )
            }
            // Resolved here so the main hop captures immutable bindings rather
            // than this closure's mutable captures.
            let manager = self
            let rotatedProcess = monitoredProcess
            DispatchQueue.main.async {
                guard let self = manager else {
                    if case .success(let temporaryURL) = result {
                        try? FileManager.default.removeItem(at: temporaryURL)
                    }
                    _ = rotatedProcess?.resume()
                    return
                }
                // Whoever invalidated the rotation has already resumed the
                // child or seen it exit; resuming here would be a second,
                // unmatched resume.
                guard self.logRotationID == rotationID,
                      let monitoredProcess = rotatedProcess,
                      self.process === monitoredProcess,
                      monitoredProcess.isRunning
                else {
                    if case .success(let temporaryURL) = result {
                        try? FileManager.default.removeItem(at: temporaryURL)
                    }
                    if self.logRotationID == rotationID { self.logRotationID = nil }
                    return
                }

                do {
                    let temporaryURL = try result.get()
                    defer { try? FileManager.default.removeItem(at: temporaryURL) }
                    try Self.installLogBackup(
                        temporaryURL,
                        at: path,
                        activeFileDescriptor: fileDescriptor
                    )
                    self.rewindPerformanceReader()
                } catch {
                    os_log(
                        .error,
                        log: self.log,
                        "log rotation failed: %{public}@",
                        String(describing: error)
                    )
                }
                self.logRotationID = nil
                _ = monitoredProcess.resume()
            }
        }
    }

    /// Preserve the newest bytes as `.1`, replace that backup atomically, and
    /// truncate the active inode so an inherited append descriptor stays valid.
    nonisolated static func rotateLog(
        at path: String,
        maximumBytes: Int,
        activeFileDescriptor: Int32
    ) throws {
        let temporaryURL = try makeLogBackup(at: path, maximumBytes: maximumBytes)
        do {
            try installLogBackup(
                temporaryURL,
                at: path,
                activeFileDescriptor: activeFileDescriptor
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    /// Copy the newest complete segment while the server is suspended. The
    /// caller installs it only if this rotation still owns the active process.
    nonisolated private static func makeLogBackup(at path: String, maximumBytes: Int) throws -> URL {
        let fm = FileManager.default
        let activeURL = URL(fileURLWithPath: path)
        let temporaryURL = URL(fileURLWithPath: path + ".1.tmp-\(UUID().uuidString)")
        var removeTemporaryFile = true
        defer {
            if removeTemporaryFile {
                try? fm.removeItem(at: temporaryURL)
            }
        }

        guard fm.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let input = try FileHandle(forReadingFrom: activeURL)
        let output = try FileHandle(forWritingTo: temporaryURL)
        defer {
            try? input.close()
            try? output.close()
        }

        let size = try input.seekToEnd()
        let retainedBytes = min(size, UInt64(maximumBytes))
        try input.seek(toOffset: size - retainedBytes)
        var remaining = retainedBytes
        while remaining > 0 {
            let count = Int(min(remaining, 1024 * 1024))
            guard let data = try input.read(upToCount: count), !data.isEmpty else {
                throw CocoaError(.fileReadUnknown)
            }
            try output.write(contentsOf: data)
            remaining -= UInt64(data.count)
        }
        try output.synchronize()

        // The defer above removes failed copies. A successful caller takes
        // ownership of the temporary path and atomically installs it.
        removeTemporaryFile = false
        return temporaryURL
    }

    nonisolated private static func installLogBackup(
        _ temporaryURL: URL,
        at path: String,
        activeFileDescriptor: Int32
    ) throws {
        let backupURL = URL(fileURLWithPath: path + ".1")
        let renameResult = temporaryURL.path.withCString { temporaryPath in
            backupURL.path.withCString { backupPath in
                rename(temporaryPath, backupPath)
            }
        }
        guard renameResult == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard ftruncate(activeFileDescriptor, 0) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    /// Create `directory` (and any missing parents) owner-only. A directory that
    /// already exists is left as-is: the log path is user-chosen, and
    /// silently narrowing the permissions of an existing directory — which may be
    /// a shared or project folder — is not this app's call to make.
    nonisolated static func createOwnerOnlyDirectory(_ directory: String, fm: FileManager) {
        guard !directory.isEmpty, !fm.fileExists(atPath: directory) else { return }
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
    }

    func writeLog(_ s: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let handle = logFileHandle, let data = s.data(using: .utf8) else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            // Best-effort, but a silent failure here leaves a log that looks
            // merely empty — which reads as "the server said nothing" rather
            // than "the app could not write".
            os_log(
                .error,
                log: log,
                "unable to write to server log: %{public}@",
                String(describing: error)
            )
        }
    }

    /// Truncate the active log in place so a running server can keep writing to
    /// its existing append-only file descriptor, then remove the rotated copy.
    func clearLogCollection(logPath: String) throws {
        guard logRotationID == nil else {
            throw CocoaError(.fileWriteUnknown)
        }
        let path = (logPath as NSString).expandingTildeInPath
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            rewindPerformanceReader()
        }

        let rotatedPath = path + ".1"
        if fm.fileExists(atPath: rotatedPath) {
            try fm.removeItem(atPath: rotatedPath)
        }
    }

    func launchFailureReason(logPath: String) -> String { ServerLogDiagnostics.launchFailureReason(logPath: logPath) }
    func lastLogReason(logPath: String) -> String { ServerLogDiagnostics.lastLogReason(logPath: logPath) }
}
