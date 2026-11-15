// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest

@testable import llmenubar

/// The Hugging Face token and the keychain that holds it and the API key.
final class HuggingFaceTokenTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        suiteNames = []
        super.tearDown()
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "llmenubar-config-tests-\(UUID().uuidString)"
        suiteNames.append(name)
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    private func base() -> ServerConfiguration.Config {
        var config = ServerConfiguration.Config()
        config.splashPath = "/opt/homebrew/bin/splash"
        config.modelSource = .huggingFace
        config.huggingFaceModel = "owner/repo:Q4"
        return config
    }

    // MARK: Stores

    func testTheMemoryStoreKeepsAValueAndAnEmptyOneRemovesIt() throws {
        let store = MemorySecretStore()
        XCTAssertNil(try store.read(.apiKey))
        try store.write("abc", for: .apiKey)
        try store.write("hf_1", for: .huggingFaceToken)
        XCTAssertEqual(try store.read(.apiKey), "abc")
        XCTAssertEqual(try store.read(.huggingFaceToken), "hf_1")
        try store.write("", for: .apiKey)
        XCTAssertNil(try store.read(.apiKey))
        XCTAssertEqual(try store.read(.huggingFaceToken), "hf_1")
    }

    /// The real keychain, with a service of its own that the test removes.
    /// Off by default so a test run never writes to anyone's keychain.
    func testTheKeychainStoreRoundTrips() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LLMENUBAR_KEYCHAIN_TESTS"] == "1",
                          "set LLMENUBAR_KEYCHAIN_TESTS=1 to use the login keychain")
        let store = KeychainSecretStore(service: "com.jiiim.llmenubar.tests.\(UUID().uuidString)")
        defer { for secret in Secret.allCases { try? store.write("", for: secret) } }
        XCTAssertNil(try store.read(.huggingFaceToken))
        try store.write("hf_first", for: .huggingFaceToken)
        XCTAssertEqual(try store.read(.huggingFaceToken), "hf_first")
        try store.write("hf_second", for: .huggingFaceToken)
        XCTAssertEqual(try store.read(.huggingFaceToken), "hf_second")
        XCTAssertNil(try store.read(.apiKey), "each secret has its own item")
        try store.write("", for: .huggingFaceToken)
        XCTAssertNil(try store.read(.huggingFaceToken))
        try store.write("", for: .huggingFaceToken)
    }

    func testATestProcessGetsTheMemoryStore() {
        XCTAssertTrue(SecretStores.standard() is MemorySecretStore)
    }

    // MARK: Configuration

    func testSecretsAreSavedInTheStoreAndNotInThePreferences() throws {
        let defaults = try makeDefaults()
        let store = MemorySecretStore()
        let configuration = ServerConfiguration(defaults: defaults, secrets: store)
        var config = base()
        config.apiKey = "llm-key"
        config.huggingFaceToken = "hf_secret"
        configuration.replace(with: config)
        XCTAssertNil(configuration.save())

        XCTAssertEqual(try store.read(.apiKey), "llm-key")
        XCTAssertEqual(try store.read(.huggingFaceToken), "hf_secret")
        let blob = try XCTUnwrap(defaults.data(forKey: "llmenubar.config"))
        let text = String(decoding: blob, as: UTF8.self)
        XCTAssertFalse(text.contains("llm-key"), text)
        XCTAssertFalse(text.contains("hf_secret"), text)

        let reloaded = ServerConfiguration(defaults: defaults, secrets: store).snapshot()
        XCTAssertEqual(reloaded.apiKey, "llm-key")
        XCTAssertEqual(reloaded.huggingFaceToken, "hf_secret")
    }

    func testClearingASecretRemovesItFromTheStore() throws {
        let defaults = try makeDefaults()
        let store = MemorySecretStore()
        let configuration = ServerConfiguration(defaults: defaults, secrets: store)
        var config = base()
        config.huggingFaceToken = "hf_secret"
        configuration.replace(with: config)
        configuration.save()
        config.huggingFaceToken = ""
        configuration.replace(with: config)
        configuration.save()
        XCTAssertNil(try store.read(.huggingFaceToken))
        XCTAssertEqual(ServerConfiguration(defaults: defaults, secrets: store).snapshot().huggingFaceToken, "")
    }

    func testAKeyLeftInThePreferencesIsNotUsed() throws {
        let defaults = try makeDefaults()
        var config = base()
        config.apiKey = "plain-in-prefs"
        defaults.set(try JSONEncoder().encode(config), forKey: "llmenubar.config")
        let loaded = ServerConfiguration(defaults: defaults, secrets: MemorySecretStore()).snapshot()
        XCTAssertEqual(loaded.apiKey, "")
    }

    func testAStoreThatCannotBeReadIsNotWipedByASave() throws {
        let defaults = try makeDefaults()
        let store = MemorySecretStore()
        try store.write("hf_secret", for: .huggingFaceToken)
        var config = base()
        defaults.set(try JSONEncoder().encode(config), forKey: "llmenubar.config")

        store.failure = SecretStoreError(status: -25308)
        let configuration = ServerConfiguration(defaults: defaults, secrets: store)
        XCTAssertEqual(configuration.snapshot().huggingFaceToken, "")
        store.failure = nil
        configuration.save()
        XCTAssertEqual(try store.read(.huggingFaceToken), "hf_secret",
                       "a save with nothing typed leaves what could not be read")

        config.huggingFaceToken = "hf_new"
        configuration.replace(with: config)
        configuration.save()
        XCTAssertEqual(try store.read(.huggingFaceToken), "hf_new")
    }

    func testASecretTheStoreRefusesComesBackAsAWarning() throws {
        let store = MemorySecretStore()
        let configuration = ServerConfiguration(defaults: try makeDefaults(), secrets: store)
        var config = base()
        config.huggingFaceToken = "hf_secret"
        configuration.replace(with: config)
        store.failure = SecretStoreError(status: -25293)
        let warning = try XCTUnwrap(configuration.save())
        XCTAssertTrue(warning.contains("The Hugging Face token was not saved"), warning)
    }

    func testSetupTakesAnOptionalToken() throws {
        let defaults = try makeDefaults()
        let store = MemorySecretStore()
        ServerConfiguration(defaults: defaults, secrets: store).completeInitialSetup(
            splashPath: "/opt/homebrew/bin/splash", model: .huggingFace("a/b:Q4"), huggingFaceToken: " hf_setup \n"
        )
        XCTAssertEqual(try store.read(.huggingFaceToken), "hf_setup")
        XCTAssertEqual(ServerConfiguration(defaults: defaults, secrets: store).snapshot().huggingFaceToken, "hf_setup")
    }

    // MARK: Engine environment

    func testTheTokenReachesTheEngineAsHFTokenForAHubModel() {
        var config = base()
        config.huggingFaceToken = "hf_secret"
        let environment = SplashCommand.launchEnvironment(configuration: config, inheriting: ["PATH": "/usr/bin"])
        XCTAssertEqual(environment["HF_TOKEN"], "hf_secret")
        XCTAssertFalse(SplashCommand.arguments(configuration: config).contains { $0.contains("hf_secret") })
    }

    func testTheFieldWinsOverAnHFTokenLineInTheEnvironmentText() {
        var config = base()
        config.environment = "HF_TOKEN=from-the-text\nOTHER=1"
        config.huggingFaceToken = "from-the-field"
        let environment = SplashCommand.launchEnvironment(configuration: config, inheriting: [:])
        XCTAssertEqual(environment["HF_TOKEN"], "from-the-field")
        XCTAssertEqual(environment["OTHER"], "1")
        let named = SplashCommand.environmentOverrides(configuration: config).filter { $0.name == "HF_TOKEN" }
        XCTAssertEqual(named.count, 1, "one HF_TOKEN, so the preview shows one")
    }

    func testABlankFieldLeavesTheEnvironmentTextAndTheLoginAlone() {
        var config = base()
        config.environment = "HF_TOKEN=from-the-text"
        XCTAssertEqual(SplashCommand.launchEnvironment(configuration: config, inheriting: [:])["HF_TOKEN"], "from-the-text")
        config.environment = ""
        XCTAssertNil(SplashCommand.launchEnvironment(configuration: config, inheriting: [:])["HF_TOKEN"],
                     "the engine reads the token hf auth login saved")
    }

    func testALocalModelDoesNotGetTheToken() {
        var config = base()
        config.modelSource = .local
        config.modelPath = "/models/m.gguf"
        config.huggingFaceToken = "hf_secret"
        XCTAssertNil(SplashCommand.launchEnvironment(configuration: config, inheriting: [:])["HF_TOKEN"])
    }

    func testThePreviewHidesTheToken() {
        var config = base()
        config.huggingFaceToken = "hf_secret"
        let preview = SplashCommand.preview(configuration: config)
        XCTAssertTrue(preview.contains("HF_TOKEN=REDACTED"), preview)
        XCTAssertFalse(preview.contains("hf_secret"), preview)
    }

    // MARK: Crash trace and the environment pane

    func testTheCrashTraceSwitchGivesTheEngineSPLASH_CRASH_TRACE() {
        var config = base()
        XCTAssertNil(SplashCommand.launchEnvironment(configuration: config, inheriting: [:])["SPLASH_CRASH_TRACE"])
        config.crashTrace = true
        XCTAssertEqual(SplashCommand.launchEnvironment(configuration: config, inheriting: [:])["SPLASH_CRASH_TRACE"], "1")
        XCTAssertTrue(SplashCommand.preview(configuration: config).contains("SPLASH_CRASH_TRACE=1"))
    }

    func testTheSwitchAndALineOfTheSameNameMakeOneAssignment() {
        var config = base()
        config.environment = "SPLASH_CRASH_TRACE=1\nOTHER=2"
        config.crashTrace = true
        let named = SplashCommand.environmentOverrides(configuration: config).filter { $0.name == "SPLASH_CRASH_TRACE" }
        XCTAssertEqual(named.count, 1)
        config.crashTrace = false
        XCTAssertEqual(SplashCommand.launchEnvironment(configuration: config, inheriting: [:])["SPLASH_CRASH_TRACE"], "1",
                       "a line in the environment text still works with the switch off")
    }

    func testTheSwitchSurvivesARestartAndARestoreOfEngineDefaults() throws {
        let defaults = try makeDefaults()
        let store = MemorySecretStore()
        let configuration = ServerConfiguration(defaults: defaults, secrets: store)
        var config = base()
        config.crashTrace = true
        config.huggingFaceToken = "hf_secret"
        config.maxContext = "64K"
        configuration.replace(with: config)
        configuration.save()
        let reloaded = ServerConfiguration(defaults: defaults, secrets: store).snapshot()
        XCTAssertTrue(reloaded.crashTrace)

        let restored = reloaded.restoringDefaults()
        XCTAssertTrue(restored.crashTrace, "a Diagnostics setting is left alone")
        XCTAssertEqual(restored.huggingFaceToken, "hf_secret", "a credential is not an engine option")
        XCTAssertEqual(restored.maxContext, "", "an engine option is cleared")
    }

    func testEnvironmentErrorsAreShownOnTheGeneralPane() {
        XCTAssertEqual(SettingsPane.containing(.environment), .general)
        XCTAssertEqual(SettingsPane.containing(.logPath), .diagnostics)
    }

    // MARK: Validation

    func testATokenWithASpaceIsRefused() {
        var config = base()
        config.huggingFaceToken = "hf bad"
        XCTAssertNotNil(config.validationErrors()[.huggingFaceToken])
        config.huggingFaceToken = "hf_good123"
        XCTAssertNil(config.validationErrors()[.huggingFaceToken])
    }

    // MARK: The Hub request

    func testTheListingRequestCarriesTheTokenOnlyToTheHub() throws {
        let with = try XCTUnwrap(HubModelFiles.listingRequest(repository: "o/r", revision: "main", token: " hf_t "))
        XCTAssertEqual(with.url?.host, "huggingface.co")
        XCTAssertEqual(with.value(forHTTPHeaderField: "Authorization"), "Bearer hf_t")
        let without = try XCTUnwrap(HubModelFiles.listingRequest(repository: "o/r", revision: "main"))
        XCTAssertNil(without.value(forHTTPHeaderField: "Authorization"))
    }

    func testARedirectOffTheHubDropsTheToken() throws {
        var elsewhere = URLRequest(url: try XCTUnwrap(URL(string: "https://cdn.example.com/file")))
        elsewhere.setValue("Bearer hf_t", forHTTPHeaderField: "Authorization")
        XCTAssertNil(TokenRedirectGuard.redirected(elsewhere).value(forHTTPHeaderField: "Authorization"))
        var onTheHub = URLRequest(url: try XCTUnwrap(URL(string: "https://huggingface.co/api/other")))
        onTheHub.setValue("Bearer hf_t", forHTTPHeaderField: "Authorization")
        XCTAssertEqual(TokenRedirectGuard.redirected(onTheHub).value(forHTTPHeaderField: "Authorization"), "Bearer hf_t")
    }

    func testATokenWithAControlCharacterIsNeverSent() throws {
        XCTAssertNil(HubModelFiles.listingRequest(repository: "o/r", revision: "main", token: "hf_a\nX-Evil: 1")?
            .value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(HubTokenCheck.request(token: "hf bad"))
        XCTAssertNil(HubTokenCheck.request(token: "   "))
    }

    // MARK: The token check

    func testTheCheckAsksTheHubWhoAmIWithTheToken() throws {
        let request = try XCTUnwrap(HubTokenCheck.request(token: " hf_t \n"))
        XCTAssertEqual(request.url?.absoluteString, "https://huggingface.co/api/whoami-v2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer hf_t")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testOnlyA401IsARejection() {
        let named = Data(#"{"type":"user","name":"someone","auth":{}}"#.utf8)
        XCTAssertEqual(HubTokenCheck.status(statusCode: 200, data: named), .valid(name: "someone"))
        XCTAssertEqual(HubTokenCheck.status(statusCode: 200, data: Data("{}".utf8)), .valid(name: ""))
        XCTAssertEqual(HubTokenCheck.status(statusCode: 401, data: Data()), .rejected)
        XCTAssertEqual(HubTokenCheck.status(statusCode: 429, data: Data()), .unknown, "rate limited is not wrong")
        XCTAssertEqual(HubTokenCheck.status(statusCode: 500, data: Data()), .unknown)
        XCTAssertEqual(HubTokenCheck.status(statusCode: 404, data: Data()), .unknown)
    }

    /// Asks the real Hub, with a token that is not one. Off by default.
    func testTheHubRejectsAMadeUpToken() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LLMENUBAR_NETWORK_TESTS"] == "1",
                          "set LLMENUBAR_NETWORK_TESTS=1 to ask huggingface.co")
        let status = await HubTokenCheck.check(token: "hf_thisIsNotARealToken0000")
        XCTAssertEqual(status, .rejected)
    }

    func testAddingATokenIsADifferentStorageCheck() {
        let place = ModelCache.Location(path: "/tmp/hub", source: .llmenubar)
        let plain = ModelStorageCheck(model: "o/r", languageOnly: false, location: place, revision: "")
        let signedIn = ModelStorageCheck(model: "o/r", languageOnly: false, location: place, revision: "",
                                         authenticated: true)
        XCTAssertNotEqual(plain, signedIn)
    }
}
