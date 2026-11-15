// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest
@testable import llmenubar

final class SuggestedModelsTests: XCTestCase {
    private func gib(_ value: UInt64) -> UInt64 { value << 30 }

    func testNothingIsSuggestedBelow24GB() {
        XCTAssertTrue(SuggestedModel.available(physicalMemory: gib(16)).isEmpty)
    }

    func testEachMemorySizeUpToTheMacsOwnGetsOneModel() {
        let expected: [(memory: UInt64, variants: [String])] = [
            (24, ["UD-IQ3_XXS"]),
            (32, ["UD-Q4_K_M", "UD-IQ3_XXS"]),
            (48, ["UD-Q6_K", "UD-Q4_K_M", "UD-IQ3_XXS"]),
            (64, ["UD-Q8_K_XL", "UD-Q6_K", "UD-Q4_K_M", "UD-IQ3_XXS"]),
            (96, ["UD-IQ3_XXS", "UD-Q8_K_XL", "UD-Q6_K", "UD-Q4_K_M", "UD-IQ3_XXS"]),
        ]
        for (memory, variants) in expected {
            XCTAssertEqual(
                SuggestedModel.available(physicalMemory: gib(memory)).map(\.variant),
                variants,
                "\(memory) GB"
            )
        }
    }

    func testFlashNextStartsAt96GB() {
        XCTAssertFalse(SuggestedModel.available(physicalMemory: gib(64)).contains { $0.family == SuggestedModel.flashNext })
        let at96 = SuggestedModel.available(physicalMemory: gib(96))
        XCTAssertEqual(at96.first?.modelID, "unsloth/Qwen3.8-Flash-Next-GGUF:UD-IQ3_XXS")
    }

    func testAMacBetweenSizesGetsTheSizeBelow() {
        XCTAssertEqual(
            SuggestedModel.available(physicalMemory: gib(36)).first?.variant,
            "UD-Q4_K_M"
        )
    }

    func testTheBiggestMacsGetTheLargestQuantizedModel() {
        XCTAssertEqual(SuggestedModel.available(physicalMemory: gib(128)).first?.variant, "UD-Q4_K_XL")
        XCTAssertEqual(SuggestedModel.available(physicalMemory: gib(192)).first?.variant, "UD-Q6_K_XL")
        XCTAssertEqual(SuggestedModel.available(physicalMemory: gib(256)).first?.variant, "Q8_0")
        XCTAssertEqual(SuggestedModel.available(physicalMemory: gib(512)).first?.variant, "Q8_0")
    }

    func testNoModelIsUnquantized() {
        // Splash refuses a GGUF that is mostly BF16, F16 or F32.
        for model in SuggestedModel.all {
            XCTAssertFalse(["BF16", "F16", "F32"].contains(model.variant), model.modelID)
        }
    }

    func testEveryModelIDIsOneTheAppAccepts() {
        for model in SuggestedModel.all {
            XCTAssertTrue(SplashModel.isModelID(model.modelID), model.modelID)
        }
    }

    func testEveryModelFitsInTheMemoryItsTierGives() {
        for model in SuggestedModel.all {
            XCTAssertLessThan(model.sizeGiB * 1.1, Double(model.memoryTierGiB), model.modelID)
        }
    }

    func testOnlyQwen38ModelsAreOffered() {
        for model in SuggestedModel.all {
            XCTAssertTrue(model.repository.hasPrefix("unsloth/Qwen3.8-"), model.repository)
        }
    }

    func testMenuTitlesAndMemoryReadInGB() {
        XCTAssertEqual(SuggestedModel.memoryDescription(physicalMemory: gib(128)), "128 GB")
        XCTAssertEqual(
            SuggestedModel.all.first { $0.variant == "UD-Q4_K_XL" }?.menuTitle,
            "128 GB Mac: Qwen3.8 Flash Next, UD-Q4_K_XL, 104 GB"
        )
    }
}

final class SplashInstallTests: XCTestCase {
    func testKindsFollowThePath() {
        XCTAssertEqual(SplashInstall.kind(ofPath: "/opt/homebrew/bin/splash"), .homebrew)
        XCTAssertEqual(SplashInstall.kind(ofPath: "/usr/local/bin/splash"), .homebrew)
        XCTAssertEqual(SplashInstall.kind(ofPath: "/Users/x/.local/bin/splash"), .command)
        XCTAssertEqual(SplashInstall.kind(ofPath: "/Applications/Splash.app"), .desktopApp)
        XCTAssertEqual(SplashInstall.kind(ofPath: "/Users/x/Applications/Splash.app"), .desktopApp)
    }

    func testTheInstallCommandAndReleasesPage() {
        XCTAssertEqual(SplashInstall.projectURL.absoluteString, "https://github.com/incoai/splash")
        XCTAssertEqual(SplashInstall.homebrewInstallCommand, "brew install incoai/tap/splash")
        XCTAssertEqual(SplashInstall.releasesURL.absoluteString, "https://github.com/incoai/splash/releases")
        XCTAssertEqual(
            SplashInstall.documentationURL.absoluteString,
            "https://github.com/incoai/splash/blob/main/README.md"
        )
    }
}
