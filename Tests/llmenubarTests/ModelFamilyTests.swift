// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest
@testable import llmenubar

final class ModelFamilyTests: XCTestCase {
    func testEveryVariantOfAHubRepositoryIsOneFamily() {
        XCTAssertEqual(
            ModelFamily.key(huggingFaceModel: "unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M"),
            "unsloth/qwen3.8-27b-gguf"
        )
        XCTAssertEqual(
            ModelFamily.key(huggingFaceModel: "unsloth/Qwen3.8-27B-GGUF:UD-IQ3_XXS"),
            ModelFamily.key(huggingFaceModel: " Unsloth/Qwen3.8-27B-GGUF ")
        )
        XCTAssertNotEqual(
            ModelFamily.key(huggingFaceModel: "unsloth/Qwen3.8-27B-GGUF"),
            ModelFamily.key(huggingFaceModel: "unsloth/Qwen3.8-Flash-Next-GGUF")
        )
    }

    func testAHubNameStillBeingTypedHasNoFamily() {
        XCTAssertNil(ModelFamily.key(huggingFaceModel: ""))
        XCTAssertNil(ModelFamily.key(huggingFaceModel: "unsloth"))
        XCTAssertNil(ModelFamily.key(huggingFaceModel: "unsloth/"))
    }

    func testLocalFilesLoseTheirShardQuantizationAndExtension() {
        let key = ModelFamily.key(localPath:)
        XCTAssertEqual(key("/m/Qwen3.8-27B-UD-Q4_K_M.gguf"), "qwen3.8-27b")
        XCTAssertEqual(key("/m/Qwen3.8-27B-Q8_0.gguf"), "qwen3.8-27b")
        XCTAssertEqual(key("/m/Qwen3.8-27B-UD-IQ3_XXS.gguf"), "qwen3.8-27b")
        XCTAssertEqual(key("/m/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf"), "qwen3.8-flash-next")
        XCTAssertEqual(key("/m/Qwen3.8-Flash-Next-BF16.gguf"), "qwen3.8-flash-next")
        XCTAssertEqual(key("~/mlx/Qwen3.8-27B-4bit"), "qwen3.8-27b", "an MLX bit width")
        XCTAssertEqual(key("~/mlx/Qwen3.8-27B-8bit"), "qwen3.8-27b")
        XCTAssertEqual(key("~/gguf/Qwen3.8-27B-GGUF"), "qwen3.8-27b", "a folder of the model")
        XCTAssertEqual(key("/m/Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-Q4_K_M.gguf"), "qwen3.8-27b", "a file and its folder agree")
    }

    func testDifferentModelsAreDifferentFamilies() {
        XCTAssertNotEqual(
            ModelFamily.key(localPath: "/m/Qwen3.8-27B-UD-Q4_K_M.gguf"),
            ModelFamily.key(localPath: "/m/Qwen3.8-Flash-Next-UD-Q4_K_XL.gguf")
        )
        XCTAssertEqual(ModelFamily.key(localPath: "/m/Qwen3.8-27B.gguf"), "qwen3.8-27b", "27B is a size, not a quantization")
        XCTAssertNil(ModelFamily.key(localPath: ""))
        XCTAssertNil(ModelFamily.key(localPath: "/m/.gguf"))
    }

    func testTheKeyFollowsTheModelSource() {
        var config = ServerConfiguration.Config()
        config.huggingFaceModel = "a/b:Q4"
        config.modelPath = "/m/Local-Model-Q4_K_M.gguf"
        XCTAssertEqual(ModelFamily.key(of: config), "a/b")
        config.modelSource = .local
        XCTAssertEqual(ModelFamily.key(of: config), "local-model")
    }

    // MARK: Memory

    private func local(_ model: String, projector: String = "", draft: String = "") -> ServerConfiguration.Config {
        var config = ServerConfiguration.Config()
        config.modelSource = .local
        config.modelPath = model
        config.visionProjectorPath = projector
        config.draftModel = draft
        return config
    }

    func testSwitchingFamilyPutsItsFilesBack() throws {
        var memory = ModelFamilyMemory()
        memory.record(local("/m/Qwen3.8-27B-Q4_K_M.gguf", projector: "/m/27b-mmproj.gguf", draft: "/d/27b"))
        memory.record(local("/m/Qwen3.8-Flash-Next-Q4_K_XL.gguf", projector: "/m/fn-mmproj.gguf"))

        // The draft is on the 27B with its files; the model changes to Flash Next.
        let current = local("/m/Qwen3.8-Flash-Next-Q4_K_XL.gguf", projector: "/m/27b-mmproj.gguf", draft: "/d/27b")
        let restoration = try XCTUnwrap(memory.restoration(for: "qwen3.8-flash-next", current: current))
        XCTAssertEqual(restoration.visionProjector, "/m/fn-mmproj.gguf")
        XCTAssertEqual(restoration.draft, "")
        XCTAssertEqual(
            restoration.message,
            "Restored the vision projector last used with this model. Cleared the draft, which belongs to the previous model."
        )
    }

    func testAFamilyNeverAppliedStartsWithNoProjectorOrDraft() throws {
        let memory = ModelFamilyMemory()
        let current = local("/m/New-Model.gguf", projector: "/m/old-mmproj.gguf", draft: "/d/old")
        let restoration = try XCTUnwrap(memory.restoration(for: "new-model", current: current))
        XCTAssertEqual(restoration.visionProjector, "")
        XCTAssertEqual(restoration.draft, "")
        XCTAssertEqual(
            restoration.message,
            "Cleared the vision projector and draft, which belong to the previous model."
        )
    }

    func testNothingChangesWhenTheFilesAlreadyMatch() {
        var memory = ModelFamilyMemory()
        let config = local("/m/Qwen3.8-27B-Q4_K_M.gguf", projector: "/m/p.gguf")
        memory.record(config)
        XCTAssertNil(memory.restoration(for: "qwen3.8-27b", current: config))
        XCTAssertNil(ModelFamilyMemory().restoration(for: "x", current: local("/m/X.gguf")))
    }

    func testSeedingKeepsWhatIsAlreadyKnown() {
        var memory = ModelFamilyMemory()
        memory.record(local("/m/A-Q4_K_M.gguf", projector: "/m/p1.gguf"))
        memory.seed(local("/m/A-Q8_0.gguf", projector: "/m/p2.gguf"))
        XCTAssertEqual(memory.companions(for: "a")?.visionProjector, "/m/p1.gguf")
        memory.seed(local("/m/B-Q8_0.gguf", projector: "/m/pb.gguf"))
        XCTAssertEqual(memory.companions(for: "b")?.visionProjector, "/m/pb.gguf")
    }

    func testAHubModelHasNoProjectorButKeepsItsDraft() {
        var config = ServerConfiguration.Config()
        config.huggingFaceModel = "a/b:Q4"
        config.visionProjectorPath = "/stale.gguf"
        config.draftModel = "owner/draft"
        var memory = ModelFamilyMemory()
        memory.record(config)
        XCTAssertEqual(memory.companions(for: "a/b"), .init(visionProjector: "", draft: "owner/draft"))
    }

    func testADraftRevisionGoesWithItsDraft() throws {
        var config = ServerConfiguration.Config()
        config.huggingFaceModel = "a/b:Q4"
        config.draftModel = "owner/draft"
        config.draftRevision = "v1"
        var memory = ModelFamilyMemory()
        memory.record(config)

        var other = config
        other.huggingFaceModel = "c/d:Q4"
        let cleared = try XCTUnwrap(memory.restoration(for: "c/d", current: other))
        XCTAssertEqual(cleared.draftRevision, "")
        XCTAssertEqual(cleared.message, "Cleared the draft, which belongs to the previous model.")

        other = config
        other.draftModel = ""
        other.draftRevision = ""
        let restored = try XCTUnwrap(memory.restoration(for: "a/b", current: other))
        XCTAssertEqual(restored.draft, "owner/draft")
        XCTAssertEqual(restored.draftRevision, "v1")
        XCTAssertEqual(restored.message, "Restored the draft last used with this model.")
    }

    func testALeftoverDraftRevisionIsNothingToClearForLocalFiles() {
        var config = local("/m/New-Model.gguf")
        config.draftRevision = "v1"
        XCTAssertNil(ModelFamilyMemory().restoration(for: "new-model", current: config))
    }

    func testAMemorySavedWithoutADraftRevisionStillLoads() throws {
        let stored = #"{"byFamily":{"a/b":{"visionProjector":"","draft":"owner/draft"}}}"#
        let memory = try JSONDecoder().decode(ModelFamilyMemory.self, from: Data(stored.utf8))
        XCTAssertEqual(memory.companions(for: "a/b"), .init(draft: "owner/draft"))
    }

    func testRoundTrip() throws {
        var memory = ModelFamilyMemory()
        memory.record(local("/m/A-Q4_K_M.gguf", projector: "/m/p.gguf", draft: "/d"))
        let decoded = try JSONDecoder().decode(ModelFamilyMemory.self, from: JSONEncoder().encode(memory))
        XCTAssertEqual(decoded, memory)
        XCTAssertEqual(try JSONDecoder().decode(ModelFamilyMemory.self, from: Data("{}".utf8)), ModelFamilyMemory())
    }
}
