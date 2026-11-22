// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest

@testable import llmenubar

/// Drives a real `splash serve` through `ServerManager`: start, reach running,
/// serve one request, stop. It loads a model, so it runs only when asked:
///
///     LLMENUBAR_LIVE_SPLASH=/opt/homebrew/bin/splash \
///     LLMENUBAR_LIVE_MODEL=unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M \
///     swift test --filter LiveSplashTests
///
/// The model must already be installed: the launch is offline.
@MainActor
final class LiveSplashTests: XCTestCase {
    @MainActor private final class HTTPResult {
        var status: Int?
        var finished = false
        var value: (Int?, String)?
    }

    private func spin(timeout: TimeInterval, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    func testStartServeOneRequestAndStop() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let splash = environment["LLMENUBAR_LIVE_SPLASH"],
              let model = environment["LLMENUBAR_LIVE_MODEL"]
        else { throw XCTSkip("set LLMENUBAR_LIVE_SPLASH and LLMENUBAR_LIVE_MODEL to run against a real Splash") }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "llmenubar-live-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        let configuration = ServerConfiguration(defaults: defaults)
        var config = ServerConfiguration.Config()
        config.splashPath = splash
        config.huggingFaceModel = model
        config.offline = true
        config.port = 8_791
        config.maxMemory = environment["LLMENUBAR_LIVE_MEMORY"] ?? "24G"
        config.logPath = directory.appendingPathComponent("splash.log").path
        configuration.replace(with: config)
        configuration.setShowsPerformanceInMenuBar(true)

        let derived = SplashDerivedState.compute(for: configuration.snapshot())
        XCTAssertNil(derived.splashIssue)
        XCTAssertTrue(derived.build.isSplash)
        XCTAssertEqual(configuration.snapshot().validationErrors(derived: derived), [:])

        let manager = ServerManager(
            config: configuration,
            healthChecker: HealthChecker(fastInterval: 1, steadyInterval: 2),
            notificationSink: { _, _ in }
        )
        var sawRate: Double?
        let cancellable = manager.$performance.sink { performance in
            if performance.phase == .generation, let rate = performance.tokensPerSecond { sawRate = rate }
        }
        defer {
            cancellable.cancel()
            manager.stop()
        }

        manager.start()
        XCTAssertEqual(manager.status, .starting)
        let startTimeout = TimeInterval(environment["LLMENUBAR_LIVE_TIMEOUT"] ?? "") ?? 240
        spin(timeout: startTimeout) {
            if case .running = manager.status { return true }
            if case .error = manager.status { return true }
            return false
        }
        guard case .running(let pid) = manager.status else {
            let tail = (try? String(contentsOfFile: config.logPath, encoding: .utf8))
                .map { String($0.suffix(3_000)) } ?? "(no log)"
            return XCTFail("did not reach running: \(manager.status)\n--- log tail ---\n\(tail)")
        }
        XCTAssertGreaterThan(pid, 0)

        // One request, so the log has a start and an end line to read.
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8791/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
        {"model":"\(model)","messages":[{"role":"user","content":"Say hi."}],"max_tokens":16,"reasoning_effort":"none"}
        """.utf8)
        let responseState = HTTPResult()
        URLSession.shared.dataTask(with: request) { _, response, _ in
            DispatchQueue.main.async {
                responseState.status = (response as? HTTPURLResponse)?.statusCode
                responseState.finished = true
            }
        }.resume()
        spin(timeout: 60) { responseState.finished }
        XCTAssertEqual(responseState.status, 200)

        spin(timeout: 10) { sawRate != nil && manager.lastServerUsageAt != nil }
        XCTAssertNotNil(sawRate, "the request's generation rate should reach the menu-bar display")
        XCTAssertNotNil(manager.lastServerUsageAt)

        manager.stop()
        XCTAssertEqual(manager.status, .stopping)
        spin(timeout: 30) { manager.status == .stopped }
        XCTAssertEqual(manager.status, .stopped, "an intentional stop must end as Stopped, not as a crash")

        let log = try String(contentsOfFile: config.logPath, encoding: .utf8)
        XCTAssertTrue(log.contains("Ready ·"))
        XCTAssertTrue(log.contains("Done ·"))
    }

    /// The options of 1.7.0 are flagged exactly where the engine's own help
    /// does not list them: reported on an earlier Splash, silent on 1.7.0.
    ///
    ///     LLMENUBAR_LIVE_SPLASH=/path/to/splash swift test \
    ///         --filter LiveSplashTests/testTheNewOptionsAreFlaggedOnlyWhereTheEngineLacksThem
    func testTheNewOptionsAreFlaggedOnlyWhereTheEngineLacksThem() throws {
        guard let splash = ProcessInfo.processInfo.environment["LLMENUBAR_LIVE_SPLASH"]
        else { throw XCTSkip("set LLMENUBAR_LIVE_SPLASH to run against a real Splash") }

        var base = ServerConfiguration.Config()
        base.splashPath = splash
        base.huggingFaceModel = "owner/repo:Q4"
        let derived = SplashDerivedState.compute(for: base)
        XCTAssertTrue(derived.build.isSplash)
        XCTAssertFalse(derived.build.serveFlags.isEmpty, "the engine's help should have been read")
        XCTAssertEqual(base.validationErrors(derived: derived), [:], "the defaults ask for nothing new")

        var cachedStates = base
        cachedStates.cachedStates = .exact
        var everyRequest = base
        everyRequest.reasoningEffort = .low
        everyRequest.reasoningScope = .everyRequest
        var requestsWithoutOne = base
        requestsWithoutOne.reasoningEffort = .low
        var template = base
        template.chatTemplatePath = "/tmp/chat.jinja"
        var socket = base
        socket.host = "unix:/tmp/llmb.sock"
        var concurrent = base
        concurrent.maxConcurrentRequests = "8"
        var sampling = base
        sampling.applySampling("temperature=0.7")
        var recalibrate = base
        recalibrate.recalibrateANE = true

        let cases: [(name: String, config: ServerConfiguration.Config, flag: String,
                     field: ServerConfiguration.Config.Field)] = [
            ("cached states", cachedStates, "--cached-states", .cachedStates),
            ("effort for every request", everyRequest, "--reasoning-effort", .reasoningEffort),
            ("chat template", template, "--chat-template-file", .chatTemplatePath),
            // The socket is a value of `--host`, which every Splash lists; it
            // stands on `--reasoning-effort`, which came with it.
            ("UNIX socket", socket, "--reasoning-effort", .host),
            ("concurrent requests", concurrent, "--max-concurrent-requests", .maxConcurrentRequests),
            ("sampling defaults", sampling, "--sampling-default", .samplingTemperature),
            ("recalibrate the Neural Engine", recalibrate, "--recalibrate-ane", .recalibrateANE),
        ]
        for item in cases {
            let flagged = item.config.validationErrors(derived: derived)[item.field]
            XCTAssertEqual(
                flagged != nil, !derived.build.serveFlags.contains(item.flag),
                "\(item.name): flagged \(flagged ?? "no") on Splash \(derived.build.displayVersion ?? "?")"
            )
        }
        XCTAssertNil(
            requestsWithoutOne.validationErrors(derived: derived)[.reasoningEffort],
            "an effort for requests that set none is older than 1.7.0 and needs nothing new"
        )
    }

    /// What the app accepts for the options of 1.7.1 is what Splash's own
    /// parser accepts: a value the app passes gets on to the model, which does
    /// not exist; a value the app refuses is one the parser refuses.
    ///
    ///     LLMENUBAR_LIVE_SPLASH=/path/to/splash swift test \
    ///         --filter LiveSplashTests/testTheAppAcceptsTheValuesOfSplash171ExactlyAsSplashDoes
    func testTheAppAcceptsTheValuesOfSplash171ExactlyAsSplashDoes() throws {
        guard let splash = ProcessInfo.processInfo.environment["LLMENUBAR_LIVE_SPLASH"]
        else { throw XCTSkip("set LLMENUBAR_LIVE_SPLASH to run against a real Splash") }
        guard case .success(let launcher) = SplashLauncher.resolve(path: splash) else {
            return XCTFail("not a Splash: \(splash)")
        }
        var base = ServerConfiguration.Config()
        base.splashPath = splash
        base.huggingFaceModel = "owner/does-not-exist:Q4"
        base.offline = true
        base.port = 8_795
        guard SplashDerivedState.compute(for: base).build.serveFlags.contains("--sampling-default") else {
            throw XCTSkip("this Splash predates the options of 1.7.1")
        }

        func engineRefuses(_ config: ServerConfiguration.Config) throws -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launcher.executable)
            process.arguments = launcher.leadingArguments + SplashCommand.arguments(configuration: config)
            process.environment = SplashCommand.launchEnvironment(configuration: config, launcher: launcher)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return !output.contains("cannot resolve")
        }

        var checked = 0
        func compare(_ label: String, _ edit: (inout ServerConfiguration.Config) -> Void,
                     field: ServerConfiguration.Config.Field) throws {
            var config = base
            edit(&config)
            let appRefuses = config.validationErrors()[field] != nil
            let engine = try engineRefuses(config)
            XCTAssertEqual(appRefuses, engine, "\(label): the app refuses \(appRefuses), Splash \(engine)")
            checked += 1
        }
        let sampling = [
            "temperature=0", "temperature=2", "temperature=2.1", "temperature=-1", "temperature=abc", "temperature=nan",
            "top_p=1", "top_p=0", "top_p=2", "top_k=0", "top_k=-1", "top_k=40", "top_k=1.5",
            "min_p=0", "min_p=1", "min_p=1.5", "presence_penalty=-2", "presence_penalty=3",
            "frequency_penalty=2", "frequency_penalty=-2.5", "repetition_penalty=1.1", "repetition_penalty=0",
            "temperature=1e0", "temperature=1E-1", "temperature=.5", "temperature=1.", "temperature=+1",
            "temperature=1_0e-1", "temperature=1e-400", "temperature=1e999", "temperature=inf", "temperature=0x1",
            "temperature=1__0", "temperature=_1", "temperature=1_", "temperature=1e", "temperature=e1",
            "temperature=.", "temperature=", "temperature=１", "top_k=+5", "top_k=1_0", "top_k=-0", "top_k=-01",
            "top_k=-2", "top_k=5.0", "top_k=1e1", "top_k=99999999999999999999", "top_k=-99999999999999999999",
            "top_p=1e-45", "top_p=1.5e-45", "top_p=5e-324", "repetition_penalty=3.4e38",
            "repetition_penalty=3.5e38", "repetition_penalty=1e-45", "repetition_penalty=1.5e-45",
        ]
        for text in sampling {
            let name = String(text.prefix { $0 != "=" })
            let parameter = try XCTUnwrap(ServerConfiguration.Config.samplingParameters.first { $0.name == name })
            try compare(text, { $0.applySampling(text) }, field: parameter.field)
        }
        let whole = ["0", "1", "4", "8", "9", "x", "2.5", "+3", "03", "４", " 5", "3_0", "1_0", "1e0", "-1"]
        for text in whole {
            try compare("concurrent \(text)", { $0.maxConcurrentRequests = text }, field: .maxConcurrentRequests)
        }
        for text in ["0", "1", "32", "+3", "１", "1_0", "x", "-1", "1.5"] {
            try compare("queue \(text)", { $0.queueSize = text }, field: .queueSize)
        }
        try compare("recalibrate", { $0.recalibrateANE = true }, field: .recalibrateANE)
        try compare("recalibrate with the Neural Engine off", { $0.recalibrateANE = true; $0.disableANE = true },
                    field: .recalibrateANE)
        XCTAssertEqual(checked, sampling.count + whole.count + 9 + 2)
    }

    /// `--host unix:PATH` is a value of an option every Splash lists, so the
    /// app reads support for it from another option that arrived with it. Ask
    /// the real parser: an engine without it fails to bind the host at once; one
    /// with it gets on to the model, which does not exist.
    func testTheEngineTakesASocketHostExactlyWhenTheAppSaysItDoes() throws {
        guard let splash = ProcessInfo.processInfo.environment["LLMENUBAR_LIVE_SPLASH"]
        else { throw XCTSkip("set LLMENUBAR_LIVE_SPLASH to run against a real Splash") }
        guard case .success(let launcher) = SplashLauncher.resolve(path: splash) else {
            return XCTFail("not a Splash: \(splash)")
        }
        var config = ServerConfiguration.Config()
        config.splashPath = splash
        config.huggingFaceModel = "owner/does-not-exist:Q4"
        config.offline = true
        config.port = 8_794
        config.host = "unix:/tmp/llmb-parse-\(UUID().uuidString.prefix(8)).sock"
        let derived = SplashDerivedState.compute(for: config)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launcher.executable)
        process.arguments = launcher.leadingArguments + SplashCommand.arguments(configuration: config)
        process.environment = SplashCommand.launchEnvironment(configuration: config, launcher: launcher)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(
            !output.contains("cannot bind unix:"), derived.build.supportsUnixSocket,
            "Splash \(derived.build.displayVersion ?? "?") said: \(output.prefix(300))"
        )
    }

    /// Splash refuses a launch that carries an effort for every request and the
    /// variable for requests that set none, or the reverse. The app drops the
    /// variable of the kind it does not send, so the real parser must get past
    /// the arguments. The model does not exist, so the run ends there, in
    /// seconds, with Splash's complaint about the model and not about effort.
    func testAnEffortChosenHereIsNotRefusedForTheOtherKindsVariable() throws {
        guard let splash = ProcessInfo.processInfo.environment["LLMENUBAR_LIVE_SPLASH"]
        else { throw XCTSkip("set LLMENUBAR_LIVE_SPLASH to run against a real Splash") }
        guard case .success(let launcher) = SplashLauncher.resolve(path: splash) else {
            return XCTFail("not a Splash: \(splash)")
        }
        let derived = SplashDerivedState.compute(for: {
            var config = ServerConfiguration.Config()
            config.splashPath = splash
            return config
        }())
        try XCTSkipUnless(derived.build.supports("--reasoning-effort"), "this Splash has one kind of effort only")

        for scope in ServerConfiguration.ReasoningScope.allCases {
            var config = ServerConfiguration.Config()
            config.splashPath = splash
            config.huggingFaceModel = "owner/does-not-exist:Q4"
            config.offline = true
            config.port = 8_793
            config.reasoningEffort = .low
            config.reasoningScope = scope
            let inherited = ProcessInfo.processInfo.environment.merging([
                "SPLASH_DEFAULT_REASONING_EFFORT": "medium",
                "SPLASH_REASONING_EFFORT": "high",
            ]) { $1 }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: launcher.executable)
            process.arguments = launcher.leadingArguments + SplashCommand.arguments(configuration: config)
            process.environment = SplashCommand.launchEnvironment(configuration: config, launcher: launcher, inheriting: inherited)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            XCTAssertFalse(output.contains("sets the effort of requests that set none"), "\(scope): \(output.prefix(400))")
            XCTAssertFalse(output.contains("usage: splash"), "\(scope): the arguments were refused: \(output.prefix(400))")
        }
    }

    /// Splash 1.7.0's options through the app: a UNIX socket in place of a port,
    /// one effort for every request, and exact cached states. The app's own
    /// health check reaches `running` through the socket, and the model list
    /// the engine serves says what it was told.
    ///
    ///     LLMENUBAR_LIVE_SPLASH=... LLMENUBAR_LIVE_MODEL=... \
    ///     [LLMENUBAR_LIVE_TEMPLATE=/path/to/chat.jinja] \
    ///     swift test --filter LiveSplashTests/testServeOnAUnixSocketWithTheNewOptions
    func testServeOnAUnixSocketWithTheNewOptions() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let splash = environment["LLMENUBAR_LIVE_SPLASH"],
              let model = environment["LLMENUBAR_LIVE_MODEL"]
        else { throw XCTSkip("set LLMENUBAR_LIVE_SPLASH and LLMENUBAR_LIVE_MODEL to run against a real Splash") }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-live-socket-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "llmenubar-live-socket-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        // Short: a socket path holds at most 103 bytes.
        let socket = "/tmp/llmb-live-\(UUID().uuidString.prefix(8)).sock"
        let configuration = ServerConfiguration(defaults: defaults)
        var config = ServerConfiguration.Config()
        config.splashPath = splash
        config.huggingFaceModel = model
        config.offline = true
        config.host = "unix:" + socket
        config.port = 8_792
        config.reasoningEffort = .low
        config.reasoningScope = .everyRequest
        config.cachedStates = .exact
        // The options of 1.7.1, where the engine has them.
        let serves171 = SplashDerivedState.compute(for: config).build.serveFlags.contains("--sampling-default")
        if serves171 {
            config.maxConcurrentRequests = "2"
            config.applySampling("temperature=0.5, top_k=40")
            config.recalibrateANE = true
        }
        // A template of the model's family, when one is given: Splash refuses
        // one that cannot render a conversation, so serving proves it did.
        let template = environment["LLMENUBAR_LIVE_TEMPLATE"]
        if let template { config.chatTemplatePath = PathText.storingAbsolute(template) }
        config.maxMemory = environment["LLMENUBAR_LIVE_MEMORY"] ?? "24G"
        config.logPath = directory.appendingPathComponent("splash.log").path
        configuration.replace(with: config)

        let derived = SplashDerivedState.compute(for: configuration.snapshot())
        XCTAssertNil(derived.splashIssue)
        XCTAssertNil(derived.chatTemplateIssue)
        try XCTSkipUnless(derived.build.supportsUnixSocket, "this needs Splash 1.7.0 or later")
        XCTAssertEqual(configuration.snapshot().validationErrors(derived: derived), [:])

        let manager = ServerManager(
            config: configuration,
            healthChecker: HealthChecker(fastInterval: 1, steadyInterval: 2),
            notificationSink: { _, _ in }
        )
        defer { manager.stop() }

        manager.start()
        // While the model loads the engine holds the socket's lock though
        // nothing accepts yet, and a second launch must see the socket as taken.
        spin(timeout: 60) { UnixSocket.isLockHeld(for: socket) }
        XCTAssertTrue(UnixSocket.isLockHeld(for: socket), "the engine takes PATH.lock as it starts")
        if !UnixSocket.isAccepting(at: socket) {
            XCTAssertFalse(PortWaiter.isListenPortAvailable(host: "unix:" + socket, port: config.port),
                           "a loading engine holds the socket")
        }
        let startTimeout = TimeInterval(environment["LLMENUBAR_LIVE_TIMEOUT"] ?? "") ?? 240
        spin(timeout: startTimeout) {
            if case .running = manager.status { return true }
            if case .error = manager.status { return true }
            return false
        }
        guard case .running = manager.status else {
            let tail = (try? String(contentsOfFile: config.logPath, encoding: .utf8))
                .map { String($0.suffix(3_000)) } ?? "(no log)"
            return XCTFail("did not reach running over the socket: \(manager.status)\n--- log tail ---\n\(tail)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket), "the engine made the socket")
        XCTAssertEqual(UnixSocket.status(at: socket, target: "/v1/models", timeout: 5), .success(200))

        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["-s", "--unix-socket", socket, "http://localhost/v1/models"]
        let pipe = Pipe()
        curl.standardOutput = pipe
        try curl.run()
        curl.waitUntilExit()
        let body = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(body.contains("\"reasoning\""), "the model list reports what efforts do: \(body.prefix(400))")

        manager.stop()
        spin(timeout: 30) { manager.status == .stopped }
        XCTAssertEqual(manager.status, .stopped)
        spin(timeout: 5) { !FileManager.default.fileExists(atPath: socket) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket), "the engine removes its socket as it exits")
        XCTAssertFalse(UnixSocket.isLockHeld(for: socket), "and lets go of the lock")
        XCTAssertTrue(PortWaiter.isListenPortAvailable(host: "unix:" + socket, port: config.port))

        let log = try String(contentsOfFile: config.logPath, encoding: .utf8)
        XCTAssertTrue(log.contains("--reasoning-effort low"), "the launch line names the option")
        XCTAssertTrue(log.contains("--cached-states exact"))
        if serves171 {
            XCTAssertTrue(log.contains("--max-concurrent-requests 2"))
            XCTAssertTrue(log.contains("--sampling-default temperature=0.5 --sampling-default top_k=40"))
            XCTAssertTrue(log.contains("--recalibrate-ane"))
        }
        // The app stores a path in its own spelling: `/private/var` is `/var`.
        if template != nil {
            XCTAssertTrue(log.contains("--chat-template-file " + PathText.expandingTilde(config.chatTemplatePath)))
        }
        XCTAssertTrue(log.contains("--host unix:" + socket))
    }

    /// The same, for the settings a hand-typed command line carries: local
    /// files with a projector and a draft, a name of the user's own, listening
    /// on every interface, an API key, and an environment variable.
    ///
    ///     LLMENUBAR_LIVE_SPLASH=... LLMENUBAR_LIVE_LOCAL_MODEL=/models/m.gguf \
    ///     LLMENUBAR_LIVE_LOCAL_MMPROJ=/models/mmproj.gguf \
    ///     LLMENUBAR_LIVE_LOCAL_DRAFT=/models/draft-folder \
    ///     swift test --filter LiveSplashTests
    ///
    /// Splash prepares local files by reading each one once, so the first run
    /// on large files takes a while.
    func testLocalFilesWithProjectorKeyAndEnvironment() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let splash = environment["LLMENUBAR_LIVE_SPLASH"],
              let model = environment["LLMENUBAR_LIVE_LOCAL_MODEL"],
              let projector = environment["LLMENUBAR_LIVE_LOCAL_MMPROJ"],
              let draft = environment["LLMENUBAR_LIVE_LOCAL_DRAFT"]
        else { throw XCTSkip("set the LLMENUBAR_LIVE_LOCAL_* variables to run local files against a real Splash") }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-live-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "llmenubar-live-local-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        let key = "llm-live-test-key"
        let name = "local/llmenubar-live"
        var config = ServerConfiguration.Config()
        config.splashPath = splash
        config.modelSource = .local
        config.modelPath = model
        config.localModelName = name
        config.visionProjectorPath = projector
        config.draftModel = draft
        config.offline = true
        config.host = "0.0.0.0"
        config.port = 8_792
        config.apiKey = key
        config.environment = "SPLASH_CRASH_TRACE=1"
        config.maxMemory = environment["LLMENUBAR_LIVE_MEMORY"] ?? "24G"
        config.logPath = directory.appendingPathComponent("splash.log").path
        let configuration = ServerConfiguration(defaults: defaults)
        configuration.replace(with: config)

        let derived = SplashDerivedState.compute(for: configuration.snapshot())
        XCTAssertEqual(configuration.snapshot().validationErrors(derived: derived), [:])

        let manager = ServerManager(
            config: configuration,
            healthChecker: HealthChecker(fastInterval: 1, steadyInterval: 2),
            notificationSink: { _, _ in }
        )
        defer { manager.stop() }

        manager.start()
        let startTimeout = TimeInterval(environment["LLMENUBAR_LIVE_TIMEOUT"] ?? "") ?? 600
        spin(timeout: startTimeout) {
            if case .running = manager.status { return true }
            if case .error = manager.status { return true }
            return false
        }
        guard case .running = manager.status else {
            let tail = (try? String(contentsOfFile: config.logPath, encoding: .utf8))
                .map { String($0.suffix(3_000)) } ?? "(no log)"
            return XCTFail("did not reach running: \(manager.status)\n--- log tail ---\n\(tail)")
        }

        func get(_ path: String, key: String?) -> (status: Int?, body: String) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:8792\(path)")!)
            if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            let result = HTTPResult()
            URLSession.shared.dataTask(with: request) { data, response, _ in
                DispatchQueue.main.async {
                    result.value = ((response as? HTTPURLResponse)?.statusCode, String(decoding: data ?? Data(), as: UTF8.self))
                }
            }.resume()
            spin(timeout: 30) { result.value != nil }
            return result.value ?? (nil, "")
        }

        XCTAssertEqual(get("/health", key: nil).status, 200, "health stays open so the app can watch it")
        XCTAssertEqual(get("/ready", key: nil).status, 200)
        XCTAssertEqual(get("/v1/models", key: nil).status, 401, "the API requires the key")
        XCTAssertEqual(get("/v1/models", key: "wrong").status, 401)
        let models = get("/v1/models", key: key)
        XCTAssertEqual(models.status, 200)
        XCTAssertTrue(models.body.contains("\"\(name)\""), "the model is served under the chosen name")
        XCTAssertTrue(models.body.contains("pdf"), "the projector gives the model image and PDF input")

        manager.stop()
        spin(timeout: 60) { manager.status == .stopped }
        XCTAssertEqual(manager.status, .stopped)

        let log = try String(contentsOfFile: config.logPath, encoding: .utf8)
        XCTAssertFalse(log.contains(key), "the key must not be written to the log")
        XCTAssertTrue(log.contains("env:  SPLASH_CRASH_TRACE=1 SPLASH_API_KEY=REDACTED"))
        XCTAssertTrue(log.contains("--host 0.0.0.0"))
    }
}
