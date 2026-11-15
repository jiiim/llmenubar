// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest
@testable import llmenubar

final class ModelCacheTests: XCTestCase {
    private let home = "/Users/test"

    private func location(
        setting: String = "",
        environment: String = "",
        process: [String: String] = [:]
    ) -> ModelCache.Location {
        ModelCache.effectiveLocation(setting: setting, environmentText: environment, process: process, home: home)
    }

    // MARK: Which cache

    func testWithNoSettingItIsHuggingFacesDefault() {
        XCTAssertEqual(
            location(),
            .init(path: "/Users/test/.cache/huggingface/hub", source: .huggingFaceDefault)
        )
    }

    func testTheFolderChosenHereBeatsEveryOtherSetting() {
        let chosen = location(
            setting: "~/Models",
            environment: "HF_HUB_CACHE=/env",
            process: ["HF_HUB_CACHE": "/process"]
        )
        XCTAssertEqual(chosen, .init(path: "/Users/test/Models", source: .llmenubar))
    }

    func testTheUsersHuggingFaceSettingIsUsedAndNamed() {
        XCTAssertEqual(
            location(process: ["HF_HUB_CACHE": "/Volumes/Models/hf"]),
            .init(path: "/Volumes/Models/hf", source: .variable("HF_HUB_CACHE"))
        )
        XCTAssertEqual(
            location(process: ["HF_HOME": "/data/hf"]),
            .init(path: "/data/hf/hub", source: .variable("HF_HOME"))
        )
        XCTAssertEqual(
            location(process: ["XDG_CACHE_HOME": "/data/cache"]),
            .init(path: "/data/cache/huggingface/hub", source: .variable("XDG_CACHE_HOME"))
        )
    }

    func testTheCacheVariableBeatsHFHome() {
        XCTAssertEqual(
            location(process: ["HF_HOME": "/home", "HF_HUB_CACHE": "/cache"]).path,
            "/cache"
        )
    }

    func testTheShellIsNeverConsultedForTheEffectiveLocation() {
        // Only what setup saved, the environment setting and the inherited
        // environment decide; a shell profile is read once, at setup.
        XCTAssertEqual(location().source, .huggingFaceDefault)
    }

    func testVariablesFromAShellResolveToOneFolder() {
        XCTAssertEqual(
            ModelCache.location(fromVariables: ["HF_HOME": "/Volumes/Models/hf"], home: home),
            .init(path: "/Volumes/Models/hf/hub", source: .variable("HF_HOME"))
        )
        XCTAssertEqual(
            ModelCache.location(fromVariables: ["HF_HOME": "~/hf", "HF_HUB_CACHE": "/cache"], home: home)?.path,
            "/cache"
        )
        XCTAssertEqual(ModelCache.location(fromVariables: ["HF_HOME": "~/hf"], home: home)?.path, "/Users/test/hf/hub")
        XCTAssertNil(ModelCache.location(fromVariables: ["PATH": "/usr/bin"], home: home))
        XCTAssertEqual(ModelCache.Source.variable("HF_HOME").variableName, "HF_HOME")
        XCTAssertNil(ModelCache.Source.llmenubar.variableName)
    }

    func testAnInheritedSettingNeedsNoCopy() {
        XCTAssertNil(LoginShellEnvironment.cacheLocation(inheriting: ["HF_HOME": "/already"]))
    }

    func testTheEnvironmentSettingBeatsTheInheritedEnvironment() {
        XCTAssertEqual(
            location(environment: "HF_HUB_CACHE=/env", process: ["HF_HUB_CACHE": "/process"]).path,
            "/env"
        )
    }

    func testBlankValuesAreIgnored() {
        XCTAssertEqual(location(process: ["HF_HUB_CACHE": "  "]).source, .huggingFaceDefault)
    }

    // MARK: Disk

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmenubar-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testFreeSpaceIsReadFromTheNearestFolderThatExists() throws {
        let directory = try makeDirectory()
        XCTAssertNotNil(ModelCache.freeBytes(at: directory.path))
        XCTAssertNotNil(ModelCache.freeBytes(at: directory.appendingPathComponent("not/made/yet").path))
    }

    func testAnUnmountedVolumeHasNoFreeSpace() {
        XCTAssertNil(ModelCache.freeBytes(at: "/Volumes/llmenubar-not-mounted-\(UUID().uuidString)/hub"))
    }

    func testHoldsFindsAFileUnderAnyRevision() throws {
        let cache = try makeDirectory()
        let snapshot = cache.appendingPathComponent("models--o--r/snapshots/abc123")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: snapshot.appendingPathComponent("m-Q4.gguf").path, contents: Data())
        XCTAssertTrue(ModelCache.holds("m-Q4.gguf", of: "o/r", in: cache.path))
        XCTAssertFalse(ModelCache.holds("m-Q8.gguf", of: "o/r", in: cache.path))
        XCTAssertFalse(ModelCache.holds("m-Q4.gguf", of: "o/other", in: cache.path))
    }

    func testReceivedBytesCountsOnlyThisDownloadsFiles() throws {
        let cache = try makeDirectory()
        let blobs = cache.appendingPathComponent("models--o--r/blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        func write(_ name: String, bytes: Int, modified: Date) throws {
            let url = blobs.appendingPathComponent(name)
            try Data(count: bytes).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        let began = Date()
        try write("old-blob", bytes: 5_000, modified: began.addingTimeInterval(-3_600))
        try write("new.x1.incomplete", bytes: 3_000, modified: began.addingTimeInterval(10))
        try write("finished-blob", bytes: 2_000, modified: began.addingTimeInterval(20))
        XCTAssertEqual(ModelCache.receivedBytes(repository: "o/r", in: cache.path, since: began), 5_000)
        XCTAssertEqual(ModelCache.receivedBytes(repository: "o/missing", in: cache.path, since: began), 0)
    }

    // MARK: The login shell

    func testOnlyTheLinesBetweenTheMarkersAreRead() {
        let output = """
        Last login: Wed Nov 11 on ttys001
        welcome banner HF_HOME=/banner
        __LLMENUBAR_ENV_BEGIN__
        PATH=/usr/bin
        HF_HUB_CACHE=/Volumes/Models/hf
        HF_HOME=/Users/test/hf
        OTHER=1
        __LLMENUBAR_ENV_END__
        trailing noise XDG_CACHE_HOME=/no
        """
        XCTAssertEqual(
            LoginShellEnvironment.parse(output),
            ["HF_HUB_CACHE": "/Volumes/Models/hf", "HF_HOME": "/Users/test/hf"]
        )
        XCTAssertEqual(LoginShellEnvironment.parse("no markers HF_HOME=/x"), [:])
    }

    // MARK: Fitting a model

    private let listing: [HubFile] = [
        HubFile(name: "README.md", bytes: 5_000),
        HubFile(name: "Qwen3.8-27B-UD-Q4_K_M.gguf", bytes: 15_000_000_000),
        HubFile(name: "Qwen3.8-27B-UD-Q6_K.gguf", bytes: 20_000_000_000),
        HubFile(name: "Qwen3.8-27B-UD-IQ3_XXS.gguf", bytes: 10_000_000_000),
        HubFile(name: "mmproj-BF16.gguf", bytes: 900_000_000),
        HubFile(name: "mmproj-F16.gguf", bytes: 850_000_000),
    ]

    func testAVariantSelectsItsFileAndTheSmallestProjector() {
        let files = HubModelFiles.needed(from: listing, variant: "UD-Q6_K", languageOnly: false)
        XCTAssertEqual(files.map(\.name), ["Qwen3.8-27B-UD-Q6_K.gguf", "mmproj-F16.gguf"])
        XCTAssertEqual(
            HubModelFiles.needed(from: listing, variant: "UD-Q6_K", languageOnly: true).map(\.name),
            ["Qwen3.8-27B-UD-Q6_K.gguf"],
            "text only skips the projector"
        )
    }

    func testAVariantDoesNotMatchALongerName() {
        XCTAssertEqual(
            HubModelFiles.needed(from: listing, variant: "Q6_K", languageOnly: true).map(\.name),
            ["Qwen3.8-27B-UD-Q6_K.gguf"]
        )
        XCTAssertEqual(HubModelFiles.needed(from: listing, variant: "Q4_K", languageOnly: true), [])
    }

    func testShardsAndSubfoldersAreOneVariant() {
        let shards = [
            HubFile(name: "UD-Q4_K_XL/M-UD-Q4_K_XL-00001-of-00002.gguf", bytes: 60),
            HubFile(name: "UD-Q4_K_XL/M-UD-Q4_K_XL-00002-of-00002.gguf", bytes: 40),
            HubFile(name: "UD-Q2_K_XL/M-UD-Q2_K_XL-00001-of-00001.gguf", bytes: 30),
        ]
        XCTAssertEqual(
            HubModelFiles.needed(from: shards, variant: "UD-Q4_K_XL", languageOnly: true).map(\.bytes),
            [60, 40]
        )
    }

    func testARepositoryWithNoVariantIsItsWeights() {
        let mlx = [
            HubFile(name: "config.json", bytes: 1_000),
            HubFile(name: "model-00001-of-00002.safetensors", bytes: 4_000),
            HubFile(name: "model-00002-of-00002.safetensors", bytes: 3_000),
            HubFile(name: "README.md", bytes: 9_000),
            HubFile(name: ".gitattributes", bytes: 100),
        ]
        XCTAssertEqual(
            HubModelFiles.needed(from: mlx, variant: nil, languageOnly: false).map(\.name),
            ["config.json", "model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"]
        )
    }

    func testTheHubListingIsDecoded() throws {
        let json = #"{"id":"o/r","siblings":[{"rfilename":"a.gguf","size":12},{"rfilename":"b.md"}]}"#
        XCTAssertEqual(
            HubModelFiles.decode(Data(json.utf8)),
            [HubFile(name: "a.gguf", bytes: 12), HubFile(name: "b.md", bytes: nil)]
        )
        XCTAssertNil(HubModelFiles.decode(Data("{}".utf8)))
    }

    func testModelIDsAreSplit() {
        XCTAssertEqual(HubModelFiles.parse("unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M")?.variant, "UD-Q4_K_M")
        XCTAssertNil(HubModelFiles.parse("mlx-community/Qwen3.8-27B-4bit")?.variant)
        XCTAssertNil(HubModelFiles.parse("not a model"))
    }

    func testTheReportSaysFitsWontFitAndAlreadyDownloaded() async throws {
        let cache = try {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("llmenubar-fit-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            return directory
        }()
        let place = ModelCache.Location(path: cache.path, source: .llmenubar)
        let free = try XCTUnwrap(ModelCache.freeBytes(at: cache.path))

        // A model that fits.
        let small = [HubFile(name: "m-Q4.gguf", bytes: 1_000_000)]
        let fits = await ModelStorageReport.assess(model: "o/r:Q4", languageOnly: true, location: place, listing: small)
        XCTAssertEqual(fits.outcome, .fits(bytes: 1_000_000))

        // One bigger than the disk.
        let huge = [HubFile(name: "m-Q4.gguf", bytes: free + 10_000_000_000)]
        let wont = await ModelStorageReport.assess(model: "o/r:Q4", languageOnly: true, location: place, listing: huge)
        XCTAssertEqual(wont.outcome, .wontFit(bytes: free + 10_000_000_000))

        // The same file already in the cache needs nothing.
        let snapshot = cache.appendingPathComponent("models--o--r/snapshots/abc")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: snapshot.appendingPathComponent("m-Q4.gguf").path, contents: Data())
        let present = await ModelStorageReport.assess(model: "o/r:Q4", languageOnly: true, location: place, listing: huge)
        XCTAssertEqual(present.outcome, .alreadyDownloaded)

        // Text that is no model, and a listing with nothing for the variant, say nothing.
        let none = await ModelStorageReport.assess(model: "o/r:Q9", languageOnly: true, location: place, listing: small)
        XCTAssertEqual(none.outcome, .unknown)
        let junk = await ModelStorageReport.assess(model: "oops", languageOnly: true, location: place, listing: small)
        XCTAssertEqual(junk.outcome, .unknown)
    }

    func testOnlyTheMissingFilesCount() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("llmenubar-part-\(UUID().uuidString)")
        let snapshot = cache.appendingPathComponent("models--o--r/snapshots/abc")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: cache) }
        FileManager.default.createFile(atPath: snapshot.appendingPathComponent("mmproj-F16.gguf").path, contents: Data())
        let files = [HubFile(name: "m-Q4.gguf", bytes: 5_000), HubFile(name: "mmproj-F16.gguf", bytes: 700)]
        let report = await ModelStorageReport.assess(
            model: "o/r:Q4", languageOnly: false,
            location: .init(path: cache.path, source: .llmenubar), listing: files
        )
        XCTAssertEqual(report.outcome, .fits(bytes: 5_000), "the projector is already there")
    }

    func testAnyProjectorInTheCacheCountsAsTheModelsVision() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("llmenubar-proj-\(UUID().uuidString)")
        let snapshot = cache.appendingPathComponent("models--o--r/snapshots/abc")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: cache) }
        for name in ["m-Q4.gguf", "mmproj-BF16.gguf"] {
            FileManager.default.createFile(atPath: snapshot.appendingPathComponent(name).path, contents: Data())
        }
        let files = [
            HubFile(name: "m-Q4.gguf", bytes: 5_000),
            HubFile(name: "mmproj-BF16.gguf", bytes: 900),
            HubFile(name: "mmproj-F16.gguf", bytes: 850),
        ]
        let report = await ModelStorageReport.assess(
            model: "o/r:Q4", languageOnly: false,
            location: .init(path: cache.path, source: .llmenubar), listing: files
        )
        XCTAssertEqual(report.outcome, .alreadyDownloaded)
    }

    func testOutcomeLeavesSlackAndTreatsAnUnmountedVolumeAsNoVerdict() {
        XCTAssertEqual(ModelStorageReport.outcome(neededBytes: 100, freeBytes: 100), .wontFit(bytes: 100))
        XCTAssertEqual(
            ModelStorageReport.outcome(neededBytes: 100, freeBytes: 100 + ModelStorageReport.slackBytes),
            .fits(bytes: 100)
        )
        XCTAssertEqual(ModelStorageReport.outcome(neededBytes: 100, freeBytes: nil), .unknown,
                       "an unmounted volume cannot be said to fit anything")
    }
}

// MARK: - The setting in a launch

final class ModelCacheSettingTests: XCTestCase {
    private func hubConfig(cache: String = "") -> ServerConfiguration.Config {
        var config = ServerConfiguration.Config()
        config.huggingFaceModel = "o/r:Q4"
        config.modelCacheDirectory = cache
        return config
    }

    func testTheChosenFolderIsPassedAsTheCacheVariable() {
        let environment = SplashCommand.launchEnvironment(
            configuration: hubConfig(cache: "/Volumes/Models/hf"),
            inheriting: ["HF_HUB_CACHE": "/old", "PATH": "/usr/bin"]
        )
        XCTAssertEqual(environment["HF_HUB_CACHE"], "/Volumes/Models/hf")
        XCTAssertEqual(environment["PATH"], "/usr/bin")
    }

    func testTheChosenFolderBeatsTheEnvironmentSetting() {
        var config = hubConfig(cache: "/chosen")
        config.environment = "HF_HUB_CACHE=/typed"
        let environment = SplashCommand.launchEnvironment(configuration: config, inheriting: [:])
        XCTAssertEqual(environment["HF_HUB_CACHE"], "/chosen")
    }

    func testNothingIsAddedWithoutAChosenFolder() {
        let environment = SplashCommand.launchEnvironment(
            configuration: hubConfig(), inheriting: ["HF_HOME": "/process/home"]
        )
        XCTAssertNil(environment["HF_HUB_CACHE"])
        XCTAssertEqual(environment["HF_HOME"], "/process/home", "an inherited value stays")
    }

    func testNothingIsPassedForLocalFiles() {
        var config = hubConfig(cache: "/chosen")
        config.modelSource = .local
        let environment = SplashCommand.launchEnvironment(configuration: config, inheriting: [:])
        XCTAssertNil(environment["HF_HUB_CACHE"])
    }

    func testRestoringDefaultsKeepsTheLocation() {
        var config = hubConfig(cache: "/Volumes/Models/hf")
        config.maxMemory = "28G"
        let restored = config.restoringDefaults()
        XCTAssertEqual(restored.modelCacheDirectory, "/Volumes/Models/hf")
        XCTAssertEqual(restored.maxMemory, "")
    }

    func testTheFolderIsCheckedOnlyForHubModels() throws {
        var config = hubConfig(cache: "relative/folder")
        config.splashPath = "/opt/homebrew/bin/splash"
        XCTAssertNotNil(config.validationErrors()[.modelCacheDirectory])
        XCTAssertEqual(SettingsPane.containing(.modelCacheDirectory), .model)

        config.modelCacheDirectory = "/Volumes/llmenubar-not-mounted-\(UUID().uuidString)/hf"
        XCTAssertEqual(config.validationErrors()[.modelCacheDirectory], "That folder's disk is not connected.")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("llmenubar-file-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: file) }
        config.modelCacheDirectory = file.path
        XCTAssertEqual(config.validationErrors()[.modelCacheDirectory], "Choose a folder, not a file.")

        config.modelCacheDirectory = FileManager.default.temporaryDirectory.path + "/llmenubar-new-\(UUID().uuidString)"
        XCTAssertNil(config.validationErrors()[.modelCacheDirectory], "a folder not made yet is fine")

        config.modelSource = .local
        config.modelCacheDirectory = "relative/folder"
        XCTAssertNil(config.validationErrors()[.modelCacheDirectory], "files on this Mac have no cache")
    }

    func testSetupStoresTheChosenFolder() throws {
        let name = "llmenubar-config-tests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let configuration = ServerConfiguration(defaults: defaults)
        configuration.completeInitialSetup(
            splashPath: "/opt/homebrew/bin/splash",
            model: .huggingFace("o/r:Q4"),
            modelCacheDirectory: "/Volumes/Models/hf"
        )
        XCTAssertEqual(ServerConfiguration(defaults: defaults).snapshot().modelCacheDirectory, "/Volumes/Models/hf")
    }

    /// The Hub can leave a size out. It is unknown, not zero bytes that always fit.
    func testAFileWithNoSizeGivesNoVerdict() async {
        let files = [HubFile(name: "m-Q4.gguf", bytes: nil)]
        let report = await ModelStorageReport.assess(
            model: "o/r:Q4", languageOnly: true,
            location: .init(path: NSTemporaryDirectory() + "llmenubar-no-size-\(UUID().uuidString)", source: .llmenubar),
            listing: files
        )
        XCTAssertEqual(report.outcome, .unknown)
    }

    func testDecodingKeepsAMissingSizeMissing() {
        let json = Data(#"{"siblings":[{"rfilename":"a.gguf"},{"rfilename":"b.gguf","size":7}]}"#.utf8)
        XCTAssertEqual(HubModelFiles.decode(json), [HubFile(name: "a.gguf", bytes: nil), HubFile(name: "b.gguf", bytes: 7)])
    }

    func testFreeSpaceIsNeverMoreThanTheVolumeReportsAsPlainlyAvailable() throws {
        let free = try XCTUnwrap(ModelCache.freeBytes(at: NSTemporaryDirectory()))
        let plain = try URL(fileURLWithPath: NSTemporaryDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
        XCTAssertLessThanOrEqual(free, Int64(try XCTUnwrap(plain)))
    }
}
