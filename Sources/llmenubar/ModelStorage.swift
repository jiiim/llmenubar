// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation

/// A file of a Hugging Face repository, as the Hub lists it.
struct HubFile: Equatable, Sendable {
    let name: String
    /// Nil when the Hub did not give a size; that is not zero bytes.
    let bytes: Int64?
}

/// Which of a repository's files Splash fetches for a model, so the space it
/// needs can be told before the download starts. This follows Splash's own
/// choice closely, not exactly: Splash prints the real size when it starts.
enum HubModelFiles {
    /// `owner/repo` and the variant after a colon, or nil for text that is
    /// not a model ID yet.
    static func parse(_ model: String) -> (repository: String, variant: String?)? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SplashModel.isModelID(trimmed) else { return nil }
        let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
        guard let repository = parts.first else { return nil }
        return (String(repository), parts.count == 2 ? String(parts[1]) : nil)
    }

    private static let ignored: Set<String> = ["md", "gitattributes", "png", "jpg", "jpeg", "gif", "svg", "txt"]

    /// The files a start fetches. A GGUF variant is the GGUF file or the shards
    /// whose name carries it, plus the vision projector unless the model is
    /// served as text only; a repository with no variant is its weights and
    /// configuration.
    static func needed(from files: [HubFile], variant: String?, languageOnly: Bool) -> [HubFile] {
        func isGGUF(_ file: HubFile) -> Bool { file.name.lowercased().hasSuffix(".gguf") }
        func isProjector(_ file: HubFile) -> Bool { file.name.lowercased().contains("mmproj") }

        guard let variant else {
            return files.filter { file in
                let ext = (file.name as NSString).pathExtension.lowercased()
                return !isGGUF(file) && !ignored.contains(ext) && !file.name.hasPrefix(".")
            }
        }
        let escaped = NSRegularExpression.escapedPattern(for: variant.lowercased())
        let pattern = try? NSRegularExpression(pattern: "(^|[-./])\(escaped)([-./]|$)")
        let weights = files.filter { file in
            guard isGGUF(file), !isProjector(file) else { return false }
            let name = file.name.lowercased()
            return pattern?.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        }
        guard !languageOnly else { return weights }
        let projector = files.filter(isProjector).min { ($0.bytes ?? .max) < ($1.bytes ?? .max) }
        return weights + (projector.map { [$0] } ?? [])
    }

    /// The files of `repository`, from the Hub. Nil when it does not answer.
    static func listingURL(repository: String, revision: String) -> URL? {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard let encoded = (revision.isEmpty ? "main" : revision).addingPercentEncoding(withAllowedCharacters: safe) else { return nil }
        return URL(string: "https://huggingface.co/api/models/\(repository)/revision/\(encoded)?blobs=true")
    }

    /// The listing request. A token goes in the `Authorization` header, for a
    /// private or gated repository, and only to huggingface.co.
    static func listingRequest(repository: String, revision: String, token: String = "") -> URLRequest? {
        guard let url = listingURL(repository: repository, revision: revision) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if HubTokenCheck.isSendable(token), url.host == "huggingface.co" {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func fetch(repository: String, revision: String = "", token: String = "") async -> [HubFile]? {
        await fetchListing(repository: repository, revision: revision, token: token)?.files
    }

    static func fetchListing(repository: String, revision: String, token: String = "") async -> (files: [HubFile], commit: String)? {
        guard let request = listingRequest(repository: repository, revision: revision, token: token) else { return nil }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let files = decode(data),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commit = object["sha"] as? String,
              !commit.isEmpty, commit.allSatisfy({ $0.isHexDigit }) else { return nil }
        return (files, commit)
    }

    static func decode(_ data: Data) -> [HubFile]? {
        struct Listing: Decodable {
            struct Sibling: Decodable {
                let rfilename: String
                let size: Int64?
            }
            let siblings: [Sibling]?
        }
        guard let siblings = (try? JSONDecoder().decode(Listing.self, from: data))?.siblings else { return nil }
        return siblings.map { HubFile(name: $0.rfilename, bytes: $0.size) }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: TokenRedirectGuard(), delegateQueue: nil)
    }()
}

/// Drops the token from a redirect that leaves huggingface.co, so it never
/// reaches another host.
final class TokenRedirectGuard: NSObject, URLSessionTaskDelegate {
    static func redirected(_ request: URLRequest) -> URLRequest {
        guard request.url?.host != "huggingface.co" else { return request }
        var request = request
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        return request
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.redirected(request))
    }
}

/// Whether a model fits where it would download.
struct ModelStorageReport: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// The Hub did not say, or the text is no model ID.
        case unknown
        /// Every file is in the cache already.
        case alreadyDownloaded
        /// `bytes` still to fetch, and there is room.
        case fits(bytes: Int64)
        case wontFit(bytes: Int64)
    }

    let location: ModelCache.Location
    /// Free bytes on the cache's volume; nil when the volume is not mounted.
    let freeBytes: Int64?
    let outcome: Outcome

    /// Room left over for what else a download writes: a draft, the
    /// installation's own files and the volume's working space.
    static let slackBytes: Int64 = 1_000_000_000

    /// With no free-space reading (the volume is not mounted) nothing can be said
    /// about fitting; the view says the disk is not connected.
    static func outcome(neededBytes: Int64, freeBytes: Int64?) -> Outcome {
        guard let freeBytes else { return .unknown }
        return freeBytes >= neededBytes + slackBytes ? .fits(bytes: neededBytes) : .wontFit(bytes: neededBytes)
    }

    /// Work out what `model` needs beyond what the cache at `location` holds.
    /// `listing` is the repository's files, which `assess` fetches when it is
    /// nil.
    static func assess(
        model: String,
        languageOnly: Bool,
        location: ModelCache.Location,
        listing: [HubFile]? = nil,
        revision: String = "",
        resolvedCommit: String? = nil,
        token: String = ""
    ) async -> ModelStorageReport {
        let free = ModelCache.freeBytes(at: location.path)
        guard let parsed = HubModelFiles.parse(model) else {
            return ModelStorageReport(location: location, freeBytes: free, outcome: .unknown)
        }
        let files: [HubFile]
        var commit = resolvedCommit
        if let listing {
            files = listing
        } else if let fetched = await HubModelFiles.fetchListing(repository: parsed.repository, revision: revision, token: token) {
            files = fetched.files
            commit = fetched.commit
        } else {
            return ModelStorageReport(location: location, freeBytes: free, outcome: .unknown)
        }
        let needed = HubModelFiles.needed(from: files, variant: parsed.variant, languageOnly: languageOnly)
        guard !needed.isEmpty else {
            return ModelStorageReport(location: location, freeBytes: free, outcome: .unknown)
        }
        // Splash chooses among a repository's projectors by content, so any
        // projector already in the cache means the model's vision is there.
        let projectors = files.filter { $0.name.lowercased().contains("mmproj") }
        let hasProjector = projectors.contains { ModelCache.holds($0.name, of: parsed.repository, in: location.path, commit: commit) }
        let missing = needed.filter { file in
            if file.name.lowercased().contains("mmproj"), hasProjector { return false }
            return !ModelCache.holds(file.name, of: parsed.repository, in: location.path, commit: commit)
        }
        if missing.isEmpty {
            return ModelStorageReport(location: location, freeBytes: free, outcome: .alreadyDownloaded)
        }
        // A file whose size the Hub left out cannot be added up; claiming a
        // total would claim a fit that nothing supports.
        let sizes = missing.compactMap(\.bytes)
        guard sizes.count == missing.count else {
            return ModelStorageReport(location: location, freeBytes: free, outcome: .unknown)
        }
        let bytes = sizes.reduce(0, +)
        return ModelStorageReport(location: location, freeBytes: free, outcome: outcome(neededBytes: bytes, freeBytes: free))
    }
}

/// Assessment identity is stored with its result, not just used to launch a task.
struct ModelStorageCheck: Hashable {
    let model: String
    let languageOnly: Bool
    let location: ModelCache.Location
    let revision: String
    /// Whether a token goes with the request. The token is not kept here, but
    /// adding or removing one is a different check.
    var authenticated = false
}

struct ModelStorageResult {
    let check: ModelStorageCheck
    let report: ModelStorageReport
    func report(for current: ModelStorageCheck) -> ModelStorageReport? {
        check == current ? report : nil
    }
}
