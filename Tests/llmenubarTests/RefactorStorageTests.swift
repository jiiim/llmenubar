// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import XCTest
@testable import llmenubar

final class RefactorStorageTests: XCTestCase {
    func testOldModelResultIsHiddenWhileReplacementIsPending() {
        let location = ModelCache.Location(path: "/tmp/cache", source: .llmenubar)
        let old = ModelStorageCheck(model: "owner/a", languageOnly: false, location: location, revision: "main")
        let report = ModelStorageReport(location: location, freeBytes: 100, outcome: .alreadyDownloaded)
        let result = ModelStorageResult(check: old, report: report)
        XCTAssertEqual(result.report(for: old), report)
        XCTAssertNil(result.report(for: ModelStorageCheck(model: "owner/b", languageOnly: false, location: location, revision: "main")))
        XCTAssertNil(result.report(for: ModelStorageCheck(model: "owner/a", languageOnly: true, location: location, revision: "main")))
        XCTAssertNil(result.report(for: ModelStorageCheck(model: "owner/a", languageOnly: false, location: location, revision: "other")))
    }

    func testCachePresenceRequiresRequestedCommit() throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let snapshot = cache.appendingPathComponent("models--owner--model/snapshots/abc123")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data([1]).write(to: snapshot.appendingPathComponent("weights.gguf"))
        XCTAssertTrue(ModelCache.holds("weights.gguf", of: "owner/model", in: cache.path, commit: "abc123"))
        XCTAssertFalse(ModelCache.holds("weights.gguf", of: "owner/model", in: cache.path, commit: "def456"))
        XCTAssertEqual(HubModelFiles.listingURL(repository: "owner/model", revision: "refs/pr/1")?.absoluteString,
                       "https://huggingface.co/api/models/owner/model/revision/refs%2Fpr%2F1?blobs=true")
    }
}
