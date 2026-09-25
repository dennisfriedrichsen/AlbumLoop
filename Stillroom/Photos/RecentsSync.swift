import Foundation
import Photos
import StillroomCore
import UIKit

/// Shares Recently Played and resume points between Apple TVs signed in to the
/// same Apple Account, through iCloud key-value storage.
///
/// Photos gives the same album or photo a different local identifier on each
/// device, so what syncs are Photos *cloud* identifiers, converted back to this
/// device's local identifiers on arrival. Converting is expensive, so results
/// are cached and syncs are throttled. Needs tvOS 18.2 (for storable cloud
/// identifiers); on older tvOS the list stays on this Apple TV.
@MainActor
final class RecentsSync {
    private static let storeKey = "recentPlayback.v1"
    /// While a slideshow runs, the resume point changes every slide; sync at most this often.
    private static let throttle: Duration = .seconds(20)

    private let store = NSUbiquitousKeyValueStore.default
    private weak var recents: RecentPlaybackStore?
    private weak var library: PhotoLibraryModel?
    private var pending: Task<Void, Never>?
    private var isSyncing = false
    private var needsAnotherSync = false
    private let mapper = CloudIdentifierMapper()

    static var isSupported: Bool {
        if #available(tvOS 18.2, *) { true } else { false }
    }

    /// Begins syncing once Photos access is granted and albums have loaded.
    func start(recents: RecentPlaybackStore, library: PhotoLibraryModel) {
        guard Self.isSupported, self.recents == nil else { return }
        self.recents = recents
        self.library = library
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] notification in
            let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            MainActor.assumeIsolated {
                StillroomLog.library.info("iCloud: Recently Played changed on another device (reason \(reason ?? -1))")
                self?.syncNow()
            }
        }
        store.synchronize()
        syncNow()
    }

    /// Syncs soon, coalescing the frequent saves made during a slideshow.
    func scheduleSync() {
        guard recents != nil, pending == nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.throttle)
            guard !Task.isCancelled else { return }
            self?.pending = nil
            await self?.sync()
        }
    }

    /// Syncs right away, for launch, remote changes, and leaving the app.
    func syncNow() {
        guard recents != nil else { return }
        pending?.cancel()
        pending = nil
        Task { await sync() }
    }

    private func sync() async {
        guard #available(tvOS 18.2, *), let recents, let library, library.hasLoadedAlbums else { return }
        if isSyncing {
            needsAnotherSync = true
            return
        }
        isSyncing = true
        defer {
            isSyncing = false
            if needsAnotherSync {
                needsAnotherSync = false
                scheduleSync()
            }
        }

        let localItems = recents.items
        let localRemoved = recents.removed
        let localIDs = Set(localItems.map(\.albumID) + localItems.compactMap(\.resume?.assetID) + localRemoved.keys)
        let toCloud = await mapper.cloudKeys(for: localIDs)

        // This device's list, in cloud keys. Albums that can't be converted stay local only.
        let local = SyncedRecents(
            entries: localItems.compactMap { item in
                guard let albumKey = toCloud[item.albumID] else { return nil }
                return SyncedRecents.Entry(
                    albumKey: albumKey,
                    lastPlayed: item.lastPlayed,
                    resume: item.resume.flatMap { point in
                        toCloud[point.assetID].map {
                            SyncedRecents.Resume(assetKey: $0, position: point.position, total: point.total,
                                                 albumOrder: point.albumOrder.rawValue, shuffled: point.shuffled, seed: point.seed)
                        }
                    }
                )
            },
            removed: Dictionary(localRemoved.compactMap { id, date in toCloud[id].map { ($0, date) } },
                                uniquingKeysWith: max)
        )
        let remote = store.data(forKey: Self.storeKey).flatMap { try? JSONDecoder().decode(SyncedRecents.self, from: $0) }
        let merged = SyncedRecents.merged(remote ?? SyncedRecents(), local, limit: RecentPlaybackStore.maxCount, now: .now)

        if merged != remote, let data = try? JSONEncoder().encode(merged) {
            store.set(data, forKey: Self.storeKey)
            StillroomLog.library.info("iCloud: saved \(merged.entries.count) recent albums")
        }

        // Back to this device's identifiers.
        let keys = Set(merged.entries.map(\.albumKey) + merged.entries.compactMap(\.resume?.assetKey) + merged.removed.keys)
        let toLocal = await mapper.localIDs(for: keys)
        // The user may have played or removed something while identifiers were converting.
        guard recents.items == localItems, recents.removed == localRemoved else {
            needsAnotherSync = true
            return
        }

        var items: [RecentPlayback] = merged.entries.compactMap { entry in
            guard let albumID = toLocal[entry.albumKey] else { return nil }
            let resume = entry.resume.flatMap { resume -> ResumePoint? in
                guard let assetID = toLocal[resume.assetKey] else { return nil }
                return ResumePoint(assetID: assetID, position: resume.position, total: resume.total,
                                   albumOrder: AlbumOrder(rawValue: resume.albumOrder) ?? .album,
                                   shuffled: resume.shuffled, seed: resume.seed)
            }
            return RecentPlayback(albumID: albumID, lastPlayed: entry.lastPlayed, resume: resume)
        }
        // Keep albums that couldn't be converted, so nothing disappears here.
        let synced = Set(items.map(\.albumID))
        items += localItems.filter { toCloud[$0.albumID] == nil && !synced.contains($0.albumID) }
        items.sort { $0.lastPlayed > $1.lastPlayed }

        var removed = localRemoved.filter { toCloud[$0.key] == nil }
        for (key, date) in merged.removed {
            if let id = toLocal[key] { removed[id] = date }
        }
        let before = recents.items.map(\.albumID)
        recents.replace(items: items, removed: removed)
        if recents.items.map(\.albumID) != before {
            StillroomLog.library.info("iCloud: Recently Played now has \(recents.items.count) albums")
        }
    }
}

/// Converts between this device's Photos local identifiers and cloud
/// identifiers (stored as their archival strings), with a cache both ways.
private final class CloudIdentifierMapper: @unchecked Sendable {
    // Only touched on the main actor; conversions run on BlockingWork.
    private var toCloud: [String: String] = [:]
    private var toLocal: [String: String] = [:]

    @MainActor
    func cloudKeys(for localIDs: Set<String>) async -> [String: String] {
        guard #available(tvOS 18.2, *) else { return [:] }
        let missing = Array(localIDs.filter { toCloud[$0] == nil })
        if !missing.isEmpty {
            let found: [String: String] = await BlockingWork.run(qos: .utility) {
                var result: [String: String] = [:]
                for (local, mapping) in PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: missing) {
                    if case .success(let cloud) = mapping { result[local] = cloud.archivalStringValue }
                }
                return result
            }
            for (local, cloud) in found {
                toCloud[local] = cloud
                toLocal[cloud] = local
            }
            if found.count < missing.count {
                StillroomLog.library.info("iCloud: \(missing.count - found.count) of \(missing.count) identifiers have no cloud identifier")
            }
        }
        return toCloud.filter { localIDs.contains($0.key) }
    }

    @MainActor
    func localIDs(for cloudKeys: Set<String>) async -> [String: String] {
        guard #available(tvOS 18.2, *) else { return [:] }
        let missing = Array(cloudKeys.filter { toLocal[$0] == nil })
        if !missing.isEmpty {
            let found: [String: String] = await BlockingWork.run(qos: .utility) {
                let identifiers = missing.compactMap { PHCloudIdentifier(archivalStringValue: $0) }
                var result: [String: String] = [:]
                for (cloud, mapping) in PHPhotoLibrary.shared().localIdentifierMappings(for: identifiers) {
                    if case .success(let local) = mapping { result[cloud.archivalStringValue] = local }
                }
                return result
            }
            for (cloud, local) in found {
                toLocal[cloud] = local
                toCloud[local] = cloud
            }
            if found.count < missing.count {
                StillroomLog.library.info("iCloud: \(missing.count - found.count) of \(missing.count) cloud identifiers not in this library")
            }
        }
        return toLocal.filter { cloudKeys.contains($0.key) }
    }
}
