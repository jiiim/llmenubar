// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest

@testable import llmenubar

final class SplashBuildTests: XCTestCase {
    func testVersionOutput() {
        XCTAssertEqual(SplashBuild.parseIdentity(fromVersionOutput: "Splash 1.5.0\n"), .splash(version: "1.5.0"))
        XCTAssertEqual(SplashBuild.parseIdentity(fromVersionOutput: "Splash 12.0\n"), .splash(version: "12.0"))
        XCTAssertEqual(
            SplashBuild.parseIdentity(fromVersionOutput: "Splash (source checkout)\n"),
            .splash(version: "source checkout")
        )
        // A build between releases is named by git describe.
        XCTAssertEqual(
            SplashBuild.parseIdentity(fromVersionOutput: "Splash 1.5.0-42-g705ad7ac\n"),
            .splash(version: "1.5.0-42-g705ad7ac")
        )
        XCTAssertEqual(
            SplashBuild.parseIdentity(fromVersionOutput: "Splash 1.6.0-rc1+local"),
            .splash(version: "1.6.0-rc1+local")
        )
        for output in ["", "\n", "ds4-server 1.0", "Splashy 1.0", "Splash beta", "Splash", "usage: splash",
                       "Python 3.13.1", "Splash 1.5.0 extra words"] {
            XCTAssertEqual(SplashBuild.parseIdentity(fromVersionOutput: output), .notSplash, output)
        }
    }

    func testOptionsAreReadFromHelp() {
        let help = """
        usage: splash serve [-h] --model OWNER/REPO[:VARIANT] [--model-dir PATH]
                            [--mmproj FILE] [--revision REVISION]
                            [--allowed-origin ORIGIN] [--api-key KEY] [--no-webui]

        options:
          -h, --help            show this help message and exit
          --max-memory SIZE     Metal memory budget, e.g. 28G; --max-context is separate
          --kv-format {int8,bf16}
                                target KV cache storage (default: int8)

        Examples:
          splash serve --model unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M --max-context 128K
        a--b and ---c and x-y are not options
        """
        let flags = SplashBuild.parseServeFlags(fromHelp: help)
        for flag in ["--model", "--model-dir", "--mmproj", "--revision", "--allowed-origin", "--api-key",
                     "--no-webui", "--help", "--max-memory", "--max-context", "--kv-format"] {
            XCTAssertTrue(flags.contains(flag), flag)
        }
        for flag in ["--b", "---c", "--c", "-h", "--"] {
            XCTAssertFalse(flags.contains(flag), flag)
        }
    }

    func testSupportsGivesTheBenefitOfTheDoubtOnlyWithoutKnowledge() {
        XCTAssertTrue(SplashBuild.unknown.supports("--anything"))
        XCTAssertTrue(SplashBuild(identity: .splash(version: "1.5.0"), serveFlags: []).supports("--anything"))
        let known = SplashBuild(identity: .splash(version: "1.5.0"), serveFlags: ["--model"])
        XCTAssertTrue(known.supports("--model"))
        XCTAssertFalse(known.supports("--mmproj"))
    }

    // MARK: Inspecting a real executable

    private func makeExecutable(_ script: String, name: String = "splash") throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testInspectingASplashReadsVersionAndOptions() throws {
        let path = try makeExecutable("""
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "Splash 1.5.0"; exit 0; fi
        if [ "$1" = "serve" ] && [ "$2" = "--help" ]; then
            echo "usage: splash serve [--model M] [--mmproj F] [--queue-size N]"
            exit 0
        fi
        exit 2
        """)

        let build = SplashBuild.inspecting(path: path)
        XCTAssertEqual(build.identity, .splash(version: "1.5.0"))
        XCTAssertEqual(build.displayVersion, "1.5.0")
        XCTAssertTrue(build.isSplash)
        XCTAssertEqual(build.serveFlags, ["--model", "--mmproj", "--queue-size"])
    }

    func testInspectingAnotherProgramSaysSo() throws {
        let path = try makeExecutable("#!/bin/sh\necho 'ds4-server: unknown option'\nexit 0\n")
        XCTAssertEqual(SplashBuild.inspecting(path: path).identity, .notSplash)

        let refuses = try makeExecutable("#!/bin/sh\nexit 3\n")
        XCTAssertEqual(SplashBuild.inspecting(path: refuses).identity, .notSplash)
    }

    func testInspectingAMissingOrNonExecutableFileLearnsNothing() throws {
        XCTAssertEqual(SplashBuild.inspecting(path: "/nonexistent/splash"), .unknown)
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("llmenubar-plain-\(UUID().uuidString)")
        try Data("x".utf8).write(to: plain)
        addTeardownBlock { try? FileManager.default.removeItem(at: plain) }
        XCTAssertEqual(SplashBuild.inspecting(path: plain.path), .unknown)
    }

    func testASplashThatCannotListItsOptionsIsStillSplash() throws {
        let path = try makeExecutable("""
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "Splash 1.5.0"; exit 0; fi
        exit 1
        """)
        let build = SplashBuild.inspecting(path: path)
        XCTAssertEqual(build.identity, .splash(version: "1.5.0"))
        XCTAssertTrue(build.serveFlags.isEmpty)
        XCTAssertTrue(build.supports("--mmproj"))
    }

    func testDerivedStateReportsWhyTheExecutableIsRefused() throws {
        var config = ServerConfiguration.Config()
        config.splashPath = try makeExecutable("#!/bin/sh\necho 'Python 3.13'\n")
        config.huggingFaceModel = "a/b"
        XCTAssertEqual(SplashDerivedState.compute(for: config).splashIssue, "Choose splash, not another executable.")

        config.splashPath = "/nonexistent/splash"
        XCTAssertEqual(SplashDerivedState.compute(for: config).splashIssue, SplashLauncher.Issue.notAnExecutable.message)

        config.splashPath = try makeExecutable("#!/bin/sh\necho 'Splash 1.5.0'\n")
        XCTAssertNil(SplashDerivedState.compute(for: config).splashIssue)
    }

    func testFoldersAndEmptyAppsAreExplainedNotJustRefused() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-app-\(UUID().uuidString)")
        let app = directory.appendingPathComponent("Other.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(SplashDerivedState.inspectSplash(atPath: app.path).issue, SplashLauncher.Issue.appWithoutRuntime.message)
        XCTAssertEqual(SplashDerivedState.inspectSplash(atPath: directory.path).issue, SplashLauncher.Issue.folder.message)
        XCTAssertEqual(
            SplashDerivedState.inspectSplash(atPath: directory.appendingPathComponent("none").path).issue,
            SplashLauncher.Issue.notAnExecutable.message
        )
    }

    func testDerivedStateReadsTheLocalFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-derived-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let model = directory.appendingPathComponent("m.gguf")
        try Data("GGUF....".utf8).write(to: model)
        let projector = directory.appendingPathComponent("mmproj.gguf")
        try Data("nope".utf8).write(to: projector)

        var config = ServerConfiguration.Config()
        config.modelSource = .local
        config.modelPath = model.path
        config.visionProjectorPath = projector.path
        config.draftModel = directory.appendingPathComponent("no-draft").path

        let state = SplashDerivedState.compute(for: config)
        XCTAssertNil(state.modelIssue)
        XCTAssertEqual(state.visionProjectorIssue, "That file is not a GGUF.")
        XCTAssertEqual(state.draftIssue, "Choose the folder of a DFlash2 draft.")

        config.languageOnly = true
        XCTAssertNil(SplashDerivedState.compute(for: config).visionProjectorIssue)
    }

    func testOnlyAnEngineWithTheOptionStoresCachedStatesApart() {
        let before = SplashBuild(identity: .splash(version: "1.6.1"), serveFlags: ["--model", "--state-format"])
        let after = SplashBuild(identity: .splash(version: "1.7.0"), serveFlags: ["--model", "--state-format", "--cached-states"])
        XCTAssertFalse(before.hasCachedStatesOption, "1.6.1 stores them in the recurrent state's format")
        XCTAssertTrue(after.hasCachedStatesOption)
        XCTAssertTrue(SplashBuild.unknown.hasCachedStatesOption, "an engine not inspected gets the benefit of the doubt")
    }
}
