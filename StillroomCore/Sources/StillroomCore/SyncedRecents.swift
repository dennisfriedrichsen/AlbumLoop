import Foundation

/// The Recently Played list as shared between Apple TVs through iCloud.
///
/// Albums and photos are identified by *keys* that mean the same thing on every
/// device (Photos cloud identifiers), not by per-device local identifiers.
/// Merging is last-writer-wins per album, and removals travel as tombstones so
/// an album removed on one Apple TV doesn't come back from another.
public struct SyncedRecents: Codable, Equatable, Sendable {
    public struct Resume: Codable, Equatable, Sendable {
        public var assetKey: String
        public var position: Int
        public var total: Int
        public var albumOrder: String
        public var shuffled: Bool
        public var seed: UInt64

        public init(assetKey: String, position: Int, total: Int, albumOrder: String, shuffled: Bool, seed: UInt64) {
            self.assetKey = assetKey
            self.position = position
            self.total = total
            self.albumOrder = albumOrder
            self.shuffled = shuffled
            self.seed = seed
        }
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var albumKey: String
        public var lastPlayed: Date
        public var resume: Resume?

        public init(albumKey: String, lastPlayed: Date, resume: Resume?) {
            self.albumKey = albumKey
            self.lastPlayed = lastPlayed
            self.resume = resume
        }
    }

    /// Newest first.
    public var entries: [Entry]
    /// Album key → when it was removed from Recently Played.
    public var removed: [String: Date]

    public init(entries: [Entry] = [], removed: [String: Date] = [:]) {
        self.entries = entries
        self.removed = removed
    }

    /// How long a removal is remembered. An Apple TV that stays offline longer
    /// than this may bring a removed album back.
    public static let tombstoneLifetime: TimeInterval = 60 * 24 * 60 * 60

    /// Combines two lists: the most recently played state of each album wins,
    /// and a removal wins over any play that happened before it.
    public static func merged(_ lhs: SyncedRecents, _ rhs: SyncedRecents, limit: Int, now: Date) -> SyncedRecents {
        var removed = lhs.removed
        for (key, date) in rhs.removed {
            removed[key] = max(date, removed[key] ?? date)
        }
        removed = removed.filter { now.timeIntervalSince($0.value) < tombstoneLifetime }

        var newest: [String: Entry] = [:]
        for entry in lhs.entries + rhs.entries {
            if let existing = newest[entry.albumKey], existing.lastPlayed >= entry.lastPlayed { continue }
            newest[entry.albumKey] = entry
        }
        let entries = newest.values
            .filter { entry in removed[entry.albumKey].map { $0 < entry.lastPlayed } ?? true }
            .sorted { ($0.lastPlayed, $0.albumKey) > ($1.lastPlayed, $1.albumKey) }
        return SyncedRecents(entries: Array(entries.prefix(limit)), removed: removed)
    }
}
