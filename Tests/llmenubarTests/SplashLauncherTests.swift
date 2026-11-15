// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest

@testable import llmenubar

final class SplashLauncherTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-launcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// A stand-in for Splash.app: a bundle whose runtime has a Python that
    /// answers like the launcher would.
    private func makeFakeApp(in directory: URL, version: String = "Splash 1.6.0") throws -> URL {
        let app = directory.appendingPathComponent("Splash.app")
        let runtime = app.appendingPathComponent("Contents/Resources/splash")
        let bin = runtime.appendingPathComponent("python/bin")
        let install = runtime.appendingPathComponent("install")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
        // The "python" prints what the app would have started: its flags, its
        // script, and the environment it was given, then answers the launcher's
        // questions.
        let python = bin.appendingPathComponent("python3")
        try Data("""
        #!/bin/sh
        echo "args: $*" >> "${LLMENUBAR_FAKE_LOG:-/dev/null}"
        echo "nousersite: $PYTHONNOUSERSITE" >> "${LLMENUBAR_FAKE_LOG:-/dev/null}"
        shift 4
        if [ "$1" = "--version" ]; then echo "\(version)"; exit 0; fi
        if [ "$1" = "serve" ] && [ "$2" = "--help" ]; then echo "usage: splash serve [--model M] [--mmproj F]"; exit 0; fi
        exec /bin/sleep 5
        """.utf8).write(to: python)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        try Data("# launcher\n".utf8).write(to: install.appendingPathComponent("launcher.py"))
        return app
    }

    func testAnExecutableFileRunsAsItIs() throws {
        let directory = try makeDirectory()
        let splash = directory.appendingPathComponent("splash")
        try Data("#!/bin/sh\n".utf8).write(to: splash)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: splash.path)

        let launcher = try SplashLauncher.resolve(path: splash.path).get()
        XCTAssertEqual(launcher.kind, .command)
        XCTAssertEqual(launcher.executable, splash.path)
        XCTAssertEqual(launcher.leadingArguments, [])
        XCTAssertEqual(launcher.environment, [:])
        XCTAssertEqual(launcher.commandLine(["serve"]), [splash.path, "serve"])
    }

    func testTheDesktopAppRunsItsOwnPythonWithTheFlagsTheAppUses() throws {
        let directory = try makeDirectory()
        let app = try makeFakeApp(in: directory)
        let runtime = app.appendingPathComponent("Contents/Resources/splash").path

        let launcher = try SplashLauncher.resolve(path: app.path).get()
        XCTAssertEqual(launcher.kind, .desktopApp)
        XCTAssertEqual(launcher.executable, runtime + "/python/bin/python3")
        XCTAssertEqual(launcher.leadingArguments, ["-I", "-B", "-u", runtime + "/install/launcher.py"])
        XCTAssertEqual(launcher.environment, ["PYTHONNOUSERSITE": "1"])
        XCTAssertEqual(
            launcher.commandLine(["serve", "--model", "a/b"]),
            [runtime + "/python/bin/python3", "-I", "-B", "-u", runtime + "/install/launcher.py", "serve", "--model", "a/b"]
        )
    }

    func testWhatCannotBeRunIsExplained() throws {
        let directory = try makeDirectory()
        XCTAssertEqual(SplashLauncher.resolve(path: directory.path), .failure(.folder))
        XCTAssertEqual(SplashLauncher.resolve(path: directory.appendingPathComponent("none").path), .failure(.notAnExecutable))

        let plain = directory.appendingPathComponent("plain")
        try Data("x".utf8).write(to: plain)
        XCTAssertEqual(SplashLauncher.resolve(path: plain.path), .failure(.notAnExecutable))

        let emptyApp = directory.appendingPathComponent("Empty.app")
        try FileManager.default.createDirectory(at: emptyApp, withIntermediateDirectories: true)
        XCTAssertEqual(SplashLauncher.resolve(path: emptyApp.path), .failure(.appWithoutRuntime))
    }

    func testInspectingTheAppAsksItsRuntime() throws {
        let directory = try makeDirectory()
        let app = try makeFakeApp(in: directory, version: "Splash 1.5.0-42-g705ad7ac")

        let build = SplashBuild.inspecting(path: app.path)
        XCTAssertEqual(build.identity, .splash(version: "1.5.0-42-g705ad7ac"))
        XCTAssertEqual(build.serveFlags, ["--model", "--mmproj"])
        XCTAssertNil(SplashDerivedState.inspectSplash(atPath: app.path).issue)
    }

    func testThePreviewShowsTheCommandTheAppWillRun() throws {
        let directory = try makeDirectory()
        let app = try makeFakeApp(in: directory)
        var config = ServerConfiguration.Config()
        config.splashPath = app.path
        config.huggingFaceModel = "a/b"
        let runtime = app.appendingPathComponent("Contents/Resources/splash").path

        let preview = SplashCommand.preview(configuration: config)
        XCTAssertTrue(preview.hasPrefix("PYTHONNOUSERSITE=1 \(runtime)/python/bin/python3 -I -B -u \(runtime)/install/launcher.py serve --model a/b"), preview)
    }

    @MainActor
    func testLaunchingTheAppRunsItsPythonWithTheLauncherAndTheServeCommand() throws {
        let directory = try makeDirectory()
        let app = try makeFakeApp(in: directory)
        let log = directory.appendingPathComponent("fake.log")
        setenv("LLMENUBAR_FAKE_LOG", log.path, 1)
        defer { unsetenv("LLMENUBAR_FAKE_LOG") }

        var config = ServerConfiguration.Config()
        config.splashPath = app.path
        config.huggingFaceModel = "owner/repo:Q4"
        config.logPath = directory.appendingPathComponent("server.log").path
        let manager = ProcessManager()
        defer { if manager.isProcessRunning { manager.terminate() } }
        XCTAssertNotNil(manager.launch(configuration: config))

        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: log.path), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        let received = try String(contentsOf: log, encoding: .utf8)
        let runtime = app.appendingPathComponent("Contents/Resources/splash").path
        XCTAssertTrue(received.contains("args: -I -B -u \(runtime)/install/launcher.py serve --model owner/repo:Q4"), received)
        XCTAssertTrue(received.contains("nousersite: 1"), received)

        let serverLog = try String(contentsOfFile: config.logPath, encoding: .utf8)
        XCTAssertTrue(serverLog.contains("exec: \(runtime)/python/bin/python3 -I -B -u \(runtime)/install/launcher.py"), serverLog)
    }

    func testInstalledPathsAreTheOnesThatCanRun() {
        for path in SplashLauncher.installedPaths() {
            if case .failure = SplashLauncher.resolve(path: path) { XCTFail("\(path) cannot be run") }
        }
        XCTAssertTrue(SplashLauncher.description(ofPath: "/Applications/Splash.app").hasPrefix("Splash.app at "))
        XCTAssertTrue(SplashLauncher.description(ofPath: "/opt/homebrew/bin/splash").hasPrefix("splash at "))
    }
}
