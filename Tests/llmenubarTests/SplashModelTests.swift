// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest

@testable import llmenubar

final class SplashModelTests: XCTestCase {
    func testModelIDs() {
        for id in [
            "unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M",
            "unsloth/Qwen3.6-35B-A3B-GGUF",
            "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:Q2_0",
            "ornith-ai/Ornith-1.5-122B-MLX-4bit",
            "a/b",
            "_a/_b",
        ] {
            XCTAssertTrue(SplashModel.isModelID(id), id)
        }
        for id in [
            "", "noslash", "/repo", "owner/", "owner/repo:", "owner/repo:bad variant",
            "owner/repo:..", "owner/re..po", "owner/re--po", "owner/repo.git", "-owner/repo",
            "owner/repo/extra", "owner/repo:Q4:Q5", "own er/repo", ":Q4", "owner/-repo",
        ] {
            XCTAssertFalse(SplashModel.isModelID(id), id)
        }
    }

    func testRepositoryIDsTakeNoVariant() {
        XCTAssertTrue(SplashModel.isRepositoryID("owner/repo"))
        XCTAssertFalse(SplashModel.isRepositoryID("owner/repo:Q4"))
        XCTAssertFalse(SplashModel.isRepositoryID(String(repeating: "a", count: 40) + "/" + String(repeating: "b", count: 97)))
    }

    func testLocalNamesAreReducedToWhatAModelIDTakes() {
        XCTAssertEqual(SplashModel.localAPIName(forPath: "/m/Qwen3.8-27B-UD-Q4_K_M.gguf"), "local/Qwen3.8-27B-UD-Q4_K_M")
        XCTAssertEqual(SplashModel.localAPIName(forPath: "/m/Some Model (v2).GGUF"), "local/Some-Model-v2")
        XCTAssertEqual(SplashModel.localAPIName(forPath: "/m/qwen-folder"), "local/qwen-folder")
        XCTAssertEqual(SplashModel.localAPIName(forPath: "/m/a--b..c.gguf"), "local/a-b.c")
        XCTAssertEqual(SplashModel.localAPIName(forPath: "/m/モデル.gguf"), "local/model")
        XCTAssertEqual(SplashModel.localAPIName(forPath: "/m/-.-.gguf"), "local/model")
        XCTAssertEqual(SplashModel.localAPIName(forPath: "/m/repo.git"), "local/repo")
        XCTAssertEqual(SplashModel.localAPIName(forPath: ""), "local/model")
    }

    func testEveryLocalNameIsAValidModelID() {
        let paths = [
            "/m/Qwen3.8-27B-UD-Q4_K_M.gguf", "/m/Some Model (v2).gguf", "/m/a--b.gguf", "/m/..gguf",
            "/m/x.git", "/m/" + String(repeating: "n", count: 200) + ".gguf", "/m/__.gguf", "/m/%%%.gguf",
        ]
        for path in paths {
            let name = SplashModel.localAPIName(forPath: path)
            XCTAssertTrue(SplashModel.isModelID(name), "\(path) → \(name)")
        }
    }

    // MARK: Local files

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testAGGUFFileIsRecognizedByItsMagicNumber() throws {
        let directory = try temporaryDirectory()
        let good = directory.appendingPathComponent("good.gguf")
        try Data("GGUF....".utf8).write(to: good)
        let bad = directory.appendingPathComponent("bad.gguf")
        try Data("not a model".utf8).write(to: bad)

        XCTAssertEqual(try SplashModel.inspectLocalModel(atPath: good.path).get(), .ggufFile)
        XCTAssertEqual(SplashModel.inspectLocalModel(atPath: bad.path), .failure(.notGGUF))
        XCTAssertEqual(
            SplashModel.inspectLocalModel(atPath: directory.appendingPathComponent("none.gguf").path),
            .failure(.missing)
        )
    }

    func testAFolderNeedsAModelAtItsRoot() throws {
        let empty = try temporaryDirectory()
        XCTAssertEqual(SplashModel.inspectLocalModel(atPath: empty.path), .failure(.emptyFolder))

        let gguf = try temporaryDirectory()
        try Data("GGUF".utf8).write(to: gguf.appendingPathComponent("m.gguf"))
        XCTAssertEqual(try SplashModel.inspectLocalModel(atPath: gguf.path).get(), .folder)

        let mlx = try temporaryDirectory()
        try Data("{}".utf8).write(to: mlx.appendingPathComponent("model.safetensors"))
        XCTAssertEqual(try SplashModel.inspectLocalModel(atPath: mlx.path).get(), .folder)
    }

    func testTildePathsAreResolved() throws {
        XCTAssertEqual(
            SplashModel.inspectLocalModel(atPath: "~/llmenubar-no-such-\(UUID().uuidString)"),
            .failure(.missing)
        )
    }
}
