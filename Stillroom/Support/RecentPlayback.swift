import Foundation
import Observation
import StillroomCore

/// Where a slideshow was left, so it can pick up at the same photo.
struct ResumePoint: Codable, Hashable, Sendable {
    /// PhotoKit local identifier of the first photo on the slide being shown.
    var assetID: String
    /// 0-based position of that photo within the cycle.
    var position: Int
    var total: Int
    /// The order the album was snapshotted in, and the shuffle state, so the
    /// resumed slideshow continues through the same sequence.
    var albumOrder: AlbumOrder
    var shuffled: Bool
    var seed: UInt64

    /// Fraction of the album already shown, for the progress bar.
    var fraction: Double {
        total > 0 ? min(1, Double(position) / Double(total)) : 0
    }
}

/// One album on the home screen's Recently Played row.
struct RecentPlayback: Codable, Hashable, Identifiable, Sendable {
    var albumID: String
    var lastPlayed: Date
    /// Nil when the slideshow was left at its first photo or played to the end.
    var resume: ResumePoint?

    var id: String { albumID }
}

extension AlbumOrder: Codable {}

/// Recently played albums, newest first, persisted in UserDefaults.
@MainActor
@Observable
final class RecentPlaybackStore {
    static let maxCount = 12
    private static let defaultsKey = "recentPlayback"
    private static let removedKey = "recentPlaybackRemoved"

    private(set) var items: [RecentPlayback] = []
    /// Album ID → when it was removed here, so the removal can sync to other Apple TVs.
    private(set) var removed: [String: Date] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([RecentPlayback].self, from: data) {
            items = decoded
        }
        if let data = defaults.data(forKey: Self.removedKey),
           let decoded = try? JSONDecoder().decode([String: Date].self, from: data) {
            removed = decoded
        }
    }

    func entry(for albumID: String) -> RecentPlayback? {
        items.first { $0.albumID == albumID }
    }

    /// Moves the album to the front and records where it is now.
    func record(albumID: String, resume: ResumePoint?) {
        removed[albumID] = nil
        items.removeAll { $0.albumID == albumID }
        items.insert(RecentPlayback(albumID: albumID, lastPlayed: .now, resume: resume), at: 0)
        if items.count > Self.maxCount {
            items.removeLast(items.count - Self.maxCount)
        }
        save()
    }

    func remove(albumID: String) {
        items.removeAll { $0.albumID == albumID }
        removed[albumID] = .now
        save()
    }

    /// Replaces everything with the result of an iCloud sync.
    func replace(items newItems: [RecentPlayback], removed newRemoved: [String: Date]) {
        guard newItems != items || newRemoved != removed else { return }
        items = Array(newItems.prefix(Self.maxCount))
        removed = newRemoved
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        if let data = try? JSONEncoder().encode(removed) {
            defaults.set(data, forKey: Self.removedKey)
        }
    }
}
