// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest
@testable import llmenubar

final class SuggestedModelsTests: XCTestCase {
    private func gib(_ value: UInt64) -> UInt64 { value << 30 }
    private func build(_ version: String) -> SplashBuild {
        SplashBuild(identity: .splash(version: version), serveFlags: [])
    }
    private let current = SplashBuild(identity: .splash(version: "1.7.4"), serveFlags: [])

    func testNothingIsSuggestedBelow24GB() {
        XCTAssertTrue(SuggestedModel.available(physicalMemory: gib(16), build: current).isEmpty)
    }

    func testEachSectionHasOneModelForEachMemorySizeUpToTheMacsOwn() {
        let expected: [(memory: UInt64, qwen: [String], inkling: [String])] = [
            (24, ["UD-IQ3_XXS"], ["UD-IQ3_XXS"]),
            (32, ["UD-Q4_K_M", "UD-IQ3_XXS"], ["UD-IQ3_XXS"]),
            (36, ["UD-Q4_K_M", "UD-IQ3_XXS"], ["UD-Q4_K_M", "UD-IQ3_XXS"]),
            (48, ["UD-Q6_K", "UD-Q4_K_M", "UD-IQ3_XXS"], ["UD-Q8_K_XL", "UD-Q4_K_M", "UD-IQ3_XXS"]),
            (64, ["UD-Q8_K_XL", "UD-Q6_K", "UD-Q4_K_M", "UD-IQ3_XXS"], ["UD-Q8_K_XL", "UD-Q4_K_M", "UD-IQ3_XXS"]),
            (96, ["UD-IQ3_XXS", "UD-Q8_K_XL", "UD-Q6_K", "UD-Q4_K_M", "UD-IQ3_XXS"], ["UD-Q8_K_XL", "UD-Q4_K_M", "UD-IQ3_XXS"]),
        ]
        for (memory, qwen, inkling) in expected {
            let sections = SuggestedModel.sections(physicalMemory: gib(memory), build: current)
            XCTAssertEqual(sections.map(\.title), ["Qwen", "Inkling"], "\(memory) GB")
            XCTAssertEqual(sections.first { $0.title == "Qwen" }?.models.map(\.variant), qwen, "\(memory) GB")
            XCTAssertEqual(sections.first { $0.title == "Inkling" }?.models.map(\.variant) ?? [], inkling, "\(memory) GB")
        }
    }

    func testTheSectionsAreNamedForTheModelLineNotItsVersion() {
        XCTAssertEqual(Set(SuggestedModel.all.map(\.group)), ["Qwen", "Inkling"])
        XCTAssertEqual(SuggestedModel.sections(physicalMemory: gib(128), build: current).map(\.title), ["Qwen", "Inkling"])
    }

    func testInklingStartsAt24GBWithTheSmallestQuantAndTopsOutAt48GB() {
        func inkling(_ memory: UInt64) -> [SuggestedModel]? {
            SuggestedModel.sections(physicalMemory: gib(memory), build: current).first { $0.title == "Inkling" }?.models
        }
        XCTAssertNil(inkling(16))
        XCTAssertEqual(inkling(24)?.map(\.modelID), ["unsloth/Inkling-2-Mini-GGUF:UD-IQ3_XXS"])
        XCTAssertEqual(inkling(32)?.map(\.modelID), ["unsloth/Inkling-2-Mini-GGUF:UD-IQ3_XXS"])
        XCTAssertEqual(inkling(36)?.first?.modelID, "unsloth/Inkling-2-Mini-GGUF:UD-Q4_K_M")
        for memory: UInt64 in [48, 64, 128, 256, 512] {
            XCTAssertEqual(inkling(memory)?.first?.modelID, "unsloth/Inkling-2-Mini-GGUF:UD-Q8_K_XL", "\(memory) GB")
        }
    }

    func testInklingIsHiddenUnlessTheEngineIsSplash172OrLater() {
        func titles(_ build: SplashBuild) -> [String] {
            SuggestedModel.sections(physicalMemory: gib(128), build: build).map(\.title)
        }
        XCTAssertEqual(titles(build("1.7.2")), ["Qwen", "Inkling"])
        XCTAssertEqual(titles(build("1.7.3")), ["Qwen", "Inkling"])
        XCTAssertEqual(titles(build("1.7.4")), ["Qwen", "Inkling"])
        XCTAssertEqual(titles(build("1.10.0")), ["Qwen", "Inkling"])
        XCTAssertEqual(titles(build("2.0.0")), ["Qwen", "Inkling"])
        XCTAssertEqual(titles(build("1.7.1")), ["Qwen"])
        XCTAssertEqual(titles(build("1.7.0")), ["Qwen"])
        XCTAssertEqual(titles(build("1.6.1")), ["Qwen"])
        // A build after 1.7.1 may come before 1.7.2.
        XCTAssertEqual(titles(build("1.7.1-42-g705ad7ac")), ["Qwen"])
        XCTAssertEqual(titles(build("1.7.2-3-g705ad7ac")), ["Qwen", "Inkling"])
        // An engine that is unknown, not Splash, or a source checkout.
        XCTAssertEqual(titles(.unknown), ["Qwen"])
        XCTAssertEqual(titles(SplashBuild(identity: .notSplash, serveFlags: [])), ["Qwen"])
        XCTAssertEqual(titles(build("source checkout")), ["Qwen"])
    }

    func testTheSmallestInklingQuantNeedsSplash173() {
        func variants(_ version: String, _ memory: UInt64) -> [String] {
            SuggestedModel.sections(physicalMemory: gib(memory), build: build(version))
                .first { $0.title == "Inkling" }?.models.map(\.variant) ?? []
        }
        XCTAssertEqual(variants("1.7.2", 24), [])
        XCTAssertEqual(variants("1.7.3", 24), ["UD-IQ3_XXS"])
        XCTAssertEqual(variants("1.7.2", 48), ["UD-Q8_K_XL", "UD-Q4_K_M"])
        XCTAssertEqual(variants("1.7.3", 48), ["UD-Q8_K_XL", "UD-Q4_K_M", "UD-IQ3_XXS"])
        XCTAssertEqual(variants("1.7.2-3-g705ad7ac", 24), [])
    }

    func testEverySectionOfTheListIsInTheMenu() {
        let titles = SuggestedModel.sections(physicalMemory: gib(512), build: current).map(\.title)
        var expected: [String] = []
        for model in SuggestedModel.all where !expected.contains(model.group) { expected.append(model.group) }
        XCTAssertEqual(titles, expected)
    }

    func testFlashNextStartsAt96GB() {
        XCTAssertFalse(SuggestedModel.available(physicalMemory: gib(64), build: current).contains { $0.family == SuggestedModel.flashNext })
        let at96 = SuggestedModel.available(physicalMemory: gib(96), build: current)
        XCTAssertEqual(at96.first?.modelID, "unsloth/Qwen3.8-Flash-Next-GGUF:UD-IQ3_XXS")
        XCTAssertEqual(at96.filter { $0.family == SuggestedModel.flashNext }.count, 1)
    }

    func testAMacBetweenSizesGetsTheSizeBelow() {
        XCTAssertEqual(
            SuggestedModel.sections(physicalMemory: gib(40), build: current).map { $0.models.first?.variant },
            ["UD-Q4_K_M", "UD-Q4_K_M"]
        )
    }

    func testTheBiggestMacsGetTheLargestQuantizedModel() {
        func first(_ memory: UInt64) -> String? {
            SuggestedModel.sections(physicalMemory: gib(memory), build: current).first?.models.first?.variant
        }
        XCTAssertEqual(first(128), "UD-Q4_K_XL")
        XCTAssertEqual(first(192), "UD-Q6_K_XL")
        XCTAssertEqual(first(256), "Q8_0")
        XCTAssertEqual(first(512), "Q8_0")
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

    func testEachModelIsInTheSectionOfItsRepository() {
        let prefixes = [
            SuggestedModel.qwen: "unsloth/Qwen3.8-",
            SuggestedModel.inkling: "unsloth/Inkling-2-Mini-GGUF",
        ]
        for model in SuggestedModel.all {
            guard let prefix = prefixes[model.group] else {
                XCTFail("no repository prefix for the section \(model.group)")
                continue
            }
            XCTAssertTrue(model.repository.hasPrefix(prefix), model.repository)
        }
    }

    func testOnlyInklingNeedsAnEngineNewerThanTheOthers() {
        for model in SuggestedModel.all {
            XCTAssertEqual(model.minimumSplash != nil, model.group == SuggestedModel.inkling, model.modelID)
        }
        XCTAssertEqual(SuggestedModel.inklingRelease, SplashVersion(1, 7, 2))
        XCTAssertEqual(SuggestedModel.inklingVisionRelease, SplashVersion(1, 7, 3))
    }

    func testAMacUnder24GBHasNoSections() {
        XCTAssertTrue(SuggestedModel.sections(physicalMemory: gib(16), build: current).isEmpty)
    }

    func testMenuTitlesAndMemoryReadInGB() {
        XCTAssertEqual(SuggestedModel.memoryDescription(physicalMemory: gib(128)), "128 GB")
        XCTAssertEqual(
            SuggestedModel.all.first { $0.variant == "UD-Q4_K_XL" }?.menuTitle,
            "128 GB Mac: Qwen3.8 Flash Next, UD-Q4_K_XL, 104 GB"
        )
        XCTAssertEqual(
            SuggestedModel.all.first { $0.family == SuggestedModel.inklingMini && $0.variant == "UD-Q4_K_M" }?.menuTitle,
            "36 GB Mac: Inkling-2-Mini, UD-Q4_K_M, 15 GB"
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
