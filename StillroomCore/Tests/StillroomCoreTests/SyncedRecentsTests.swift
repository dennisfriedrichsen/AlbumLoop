import Foundation
import Testing
@testable import StillroomCore

@Suite("SyncedRecents")
struct SyncedRecentsTests {
    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    private func entry(_ key: String, _ minutesAgo: Double, at position: Int? = nil) -> SyncedRecents.Entry {
        SyncedRecents.Entry(
            albumKey: key,
            lastPlayed: now.addingTimeInterval(-minutesAgo * 60),
            resume: position.map {
                SyncedRecents.Resume(assetKey: "p\($0)", position: $0, total: 100, albumOrder: "album", shuffled: false, seed: 1)
            }
        )
    }

    @Test("The most recent play of an album wins, whichever device it came from")
    func newestWins() {
        let livingRoom = SyncedRecents(entries: [entry("a", 10, at: 40), entry("b", 20)])
        let bedroom = SyncedRecents(entries: [entry("a", 2, at: 55), entry("c", 30)])
        let merged = SyncedRecents.merged(livingRoom, bedroom, limit: 12, now: now)
        #expect(merged.entries.map(\.albumKey) == ["a", "b", "c"])
        #expect(merged.entries[0].resume?.position == 55)
        #expect(SyncedRecents.merged(bedroom, livingRoom, limit: 12, now: now) == merged)
    }

    @Test("A removal hides earlier plays but not later ones")
    func removals() {
        let local = SyncedRecents(entries: [entry("a", 10), entry("b", 10)])
        let remote = SyncedRecents(entries: [], removed: ["a": now.addingTimeInterval(-5 * 60), "b": now.addingTimeInterval(-20 * 60)])
        let merged = SyncedRecents.merged(local, remote, limit: 12, now: now)
        #expect(merged.entries.map(\.albumKey) == ["b"])
        #expect(merged.removed.count == 2)
    }

    @Test("The list is capped and old removals are forgotten")
    func limitsAndPruning() {
        let many = SyncedRecents(
            entries: (0..<20).map { entry("album\($0)", Double($0)) },
            removed: ["old": now.addingTimeInterval(-SyncedRecents.tombstoneLifetime - 1)]
        )
        let merged = SyncedRecents.merged(many, SyncedRecents(), limit: 12, now: now)
        #expect(merged.entries.count == 12)
        #expect(merged.entries.first?.albumKey == "album0")
        #expect(merged.removed.isEmpty)
    }
}
