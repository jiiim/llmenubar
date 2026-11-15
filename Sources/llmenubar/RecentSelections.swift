// SPDX-FileCopyrightText: Copyright James Martin
// SPDX-License-Identifier: MIT

import Foundation

/// Paths the user applied recently, most recent first.
///
/// Entries are stored in the same form the configuration stores them, so a
/// remembered path can be compared and re-applied without touching the file
/// system. This is display recall only: nothing here is part of the applied
/// configuration.
struct RecentSelections: Codable, Equatable {
    /// Enough to cover a working set without turning the picker into a list.
    static let limit = 5

    /// The path rows that keep a history.
    enum Field: String, Equatable, CaseIterable, Codable {
        case splash
        case huggingFaceModel
        case model
        case visionProjector
        case draft
    }

    private var lists: [String: [String]] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey {
        case lists
    }

    /// A missing key decodes as empty and an oversized history from a
    /// hand-edited blob is clamped, so a future field cannot discard the
    /// whole value.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lists = (try container.decodeIfPresent([String: [String]].self, forKey: .lists) ?? [:])
            .mapValues { Array($0.prefix(Self.limit)) }
    }

    /// A list's key. The projector and draft lists belong to a model family,
    /// so one family's files are not offered for another's model.
    private static func listKey(_ field: Field, _ family: String?) -> String {
        family.map { "\(field.rawValue)|\($0)" } ?? field.rawValue
    }

    func recentPaths(for field: Field, family: String? = nil) -> [String] {
        lists[Self.listKey(field, family)] ?? []
    }

    /// Move `path` to the front of its list, dropping the oldest entry past the
    /// cap. `outgoing` is the selection the change replaces; it is kept even
    /// when the list is full, because it is the way back to what the user just
    /// changed away from. Empty paths are ignored.
    ///
    /// `fileKey` names the file a path refers to, so two spellings of one
    /// file are one entry and the newer spelling replaces the older: the row
    /// shows what was just stored, and the menu should match it. The default
    /// compares the text.
    mutating func record(
        _ path: String,
        replacing outgoing: String? = nil,
        for field: Field,
        family: String? = nil,
        fileKey: (String) -> String = { $0 }
    ) {
        guard let path = Self.nonEmpty(path) else { return }
        let listKey = Self.listKey(field, family)
        var paths = lists[listKey] ?? []
        let pathKey = fileKey(path)
        paths.removeAll { fileKey($0) == pathKey }
        paths.insert(path, at: 0)
        var kept = Array(paths.prefix(Self.limit))
        if let outgoing = Self.nonEmpty(outgoing) {
            let outgoingKey = fileKey(outgoing)
            if outgoingKey != pathKey, !kept.contains(where: { fileKey($0) == outgoingKey }) {
                // Keep the outgoing selection in the last slot instead of the
                // entry that would be dropped; the new pick is the only thing
                // more recent.
                kept = Array(kept.prefix(Self.limit - 1)) + [outgoing]
            }
        }
        lists[listKey] = kept
    }

    /// Add `path` at the end of its list when it is not remembered yet, without
    /// disturbing the order of anything already there. Seeding is how a
    /// configuration that predates the history becomes reachable again: the
    /// next change adds itself in front, leaving the configured path as the
    /// way back. A path whose file is already remembered under another
    /// spelling is not added.
    mutating func seed(
        _ path: String,
        for field: Field,
        family: String? = nil,
        fileKey: (String) -> String = { $0 }
    ) {
        guard let path = Self.nonEmpty(path) else { return }
        let listKey = Self.listKey(field, family)
        var paths = lists[listKey] ?? []
        let pathKey = fileKey(path)
        guard !paths.contains(where: { fileKey($0) == pathKey }) else { return }
        // The configured path takes the oldest slot when the history is full:
        // the current selection has to stay reachable, and the least recent
        // entry is the one worth dropping.
        if paths.count >= Self.limit {
            paths.removeLast(paths.count - Self.limit + 1)
        }
        paths.append(path)
        lists[listKey] = paths
    }

    /// Forget one row's history.
    mutating func clear(_ field: Field, family: String? = nil) {
        lists[Self.listKey(field, family)] = nil
    }

    /// Drop every entry `isGone` rejects, judged with its list's field.
    mutating func prune(where isGone: (Field, String) -> Bool) {
        for key in lists.keys {
            let fieldName = key.split(separator: "|", maxSplits: 1).first.map(String.init) ?? key
            guard let field = Field(rawValue: fieldName) else { continue }
            let kept = (lists[key] ?? []).filter { !isGone(field, $0) }
            lists[key] = kept.isEmpty ? nil : kept
        }
    }

    /// A selection that was never set (the empty default) is not a path worth
    /// remembering: keeping it would spend a history slot on nothing.
    fileprivate static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

extension RecentSelections {
    /// A path an applied configuration uses, and the list it belongs to.
    struct Entry: Equatable {
        let field: Field
        let path: String
        /// The model family a projector or draft belongs to; nil for the rest.
        var family: String? = nil
    }

    /// The remembered paths `config` puts into effect. A projector or draft
    /// path counts only where it takes part in the launch, so an unused value
    /// is never remembered.
    static func entries(in config: ServerConfiguration.Config) -> [Entry] {
        var entries: [Entry] = []
        func add(_ field: Field, _ path: String, family: String? = nil) {
            guard let path = nonEmpty(path) else { return }
            entries.append(Entry(field: field, path: path, family: family))
        }
        add(.splash, config.splashPath)
        if config.modelSource == .huggingFace {
            if SplashModel.isModelID(config.huggingFaceModel.trimmingCharacters(in: .whitespaces)) {
                add(.huggingFaceModel, config.huggingFaceModel)
            }
            return entries
        }
        add(.model, config.modelPath)
        // A projector or draft is remembered with the family of its model.
        guard let family = ModelFamily.key(of: config) else { return entries }
        if !config.languageOnly {
            add(.visionProjector, config.visionProjectorPath, family: family)
        }
        if config.draftModel.hasPrefix("/") || config.draftModel.hasPrefix("~") {
            add(.draft, config.draftModel, family: family)
        }
        return entries
    }

    /// Remember what an Apply changed. A path that replaced another in the
    /// same list goes in front with the old one kept as the way back. A path
    /// that left use without a successor — a projector switched off, say —
    /// goes in front of its own list, where it is now the most recent choice.
    /// Paths that did not change are left alone.
    mutating func recordApply(
        from previous: [Entry],
        to applied: [Entry],
        fileKey: (Field) -> (String) -> String
    ) {
        for entry in applied {
            let key = fileKey(entry.field)
            let outgoing = previous.first { $0.field == entry.field && $0.family == entry.family }
            if let outgoing, key(outgoing.path) == key(entry.path) { continue }
            record(entry.path, replacing: outgoing?.path, for: entry.field, family: entry.family, fileKey: key)
        }
        for entry in previous where !applied.contains(where: { $0.field == entry.field && $0.family == entry.family }) {
            record(entry.path, for: entry.field, family: entry.family, fileKey: fileKey(entry.field))
        }
    }
}
