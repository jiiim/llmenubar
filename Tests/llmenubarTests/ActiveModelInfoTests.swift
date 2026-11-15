// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest
@testable import llmenubar

final class ActiveModelInfoTests: XCTestCase {
    private func config(aliases: String = "", announce: Bool = false) -> ServerConfiguration.Config {
        var config = ServerConfiguration.Config()
        config.modelSource = .huggingFace
        config.huggingFaceModel = "unsloth/Qwen3.8-27B-GGUF:UD-Q6_K"
        config.servedModelNames = aliases
        config.announceServedName = announce
        return config
    }

    func testTheModelsOwnIDComesFirstThenTheOtherNames() {
        let info = ActiveModelInfo.describing(config(aliases: "local-qwen, gpt-4o"))
        XCTAssertEqual(info.names, ["unsloth/Qwen3.8-27B-GGUF:UD-Q6_K", "local-qwen", "gpt-4o"])
        XCTAssertEqual(info.title, "unsloth/Qwen3.8-27B-GGUF:UD-Q6_K")
    }

    func testAnsweringAsTheFirstOtherNameListsItFirst() {
        let info = ActiveModelInfo.describing(config(aliases: "local-qwen, gpt-4o", announce: true))
        XCTAssertEqual(info.names, ["local-qwen", "unsloth/Qwen3.8-27B-GGUF:UD-Q6_K", "gpt-4o"])
        XCTAssertEqual(info.title, "unsloth/Qwen3.8-27B-GGUF:UD-Q6_K", "the row names the model, whatever the API answers as")
    }

    func testTheAnswerSettingDoesNothingWithoutOtherNames() {
        let info = ActiveModelInfo.describing(config(announce: true))
        XCTAssertEqual(info.names, ["unsloth/Qwen3.8-27B-GGUF:UD-Q6_K"])
    }

    func testARepeatedNameIsListedOnce() {
        let info = ActiveModelInfo.describing(
            config(aliases: "unsloth/Qwen3.8-27B-GGUF:UD-Q6_K, local-qwen, local-qwen")
        )
        XCTAssertEqual(info.names, ["unsloth/Qwen3.8-27B-GGUF:UD-Q6_K", "local-qwen"])
    }

    func testNoModelHasNoNames() {
        XCTAssertEqual(ActiveModelInfo.describing(ServerConfiguration.Config()), .empty)
    }
}
