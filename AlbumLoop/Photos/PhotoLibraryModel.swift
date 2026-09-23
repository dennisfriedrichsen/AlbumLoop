import AlbumLoopCore
import Observation
import Photos

/// An ordinary (non-shared) Photos album and its eligible still-photo count.
struct AlbumSummary: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    /// Still photos (including Live Photos, shown as stills). Videos are excluded.
    let photoCount: Int
    let keyAssetID: String?
}

/// Playback order for an album's photos.
enum AlbumOrder: String, CaseIterable, Identifiable, Sendable {
    /// The order PhotoKit returns for the album with no sort descriptors,
    /// which is the album's own order in Photos. Apple does not document this
    /// guarantee, so it must be checked against Photos on a real device.
    case album
    /// Documented fallback when album order is unavailable or unwanted: capture date ascending.
    case oldestFirst
    case newestFirst

    var id: String { rawValue }

    var label: String {
        switch self {
        case .album: "Album Order"
        case .oldestFirst: "Oldest First"
        case .newestFirst: "Newest First"
        }
    }
}

/// Photos authorization, availability, and album access.
@MainActor
@Observable
final class PhotoLibraryModel {
    enum Access: Equatable {
        case notDetermined
        case authorized
        case limited
        case denied
        case restricted
        case unavailable(String)
    }

    private(set) var access: Access
    private(set) var albums: [AlbumSummary] = []
    private(set) var isLoadingAlbums = false
    private(set) var hasLoadedAlbums = false
    /// Incremented (debounced) whenever the photo library changes.
    private(set) var libraryRevision = 0

    private let observer = LibraryObserver()
    private var isObserving = false
    private var changeDebounce: Task<Void, Never>?

    init() {
        access = Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        observer.onChange = { [weak self] in
            Task { @MainActor in self?.libraryDidChange() }
        }
        observer.onUnavailable = { [weak self] reason in
            Task { @MainActor in self?.access = .unavailable(reason) }
        }
        if access == .authorized || access == .limited {
            startObserving()
        }
    }

    /// Shows the system Photos permission prompt (first launch only).
    func requestAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        access = Self.map(status)
        AlbumLoopLog.library.info("Photos authorization: \(String(describing: self.access), privacy: .public)")
        if access == .authorized || access == .limited {
            startObserving()
        }
    }

    /// Re-reads the authorization state, e.g. when returning from Settings.
    func refreshAccess() {
        let updated = Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        if case .unavailable = access, updated == .authorized { return }
        access = updated
        if access == .authorized || access == .limited {
            startObserving()
        }
    }

    func loadAlbums() async {
        guard access == .authorized || access == .limited else { return }
        isLoadingAlbums = true
        defer { isLoadingAlbums = false }
        let start = ContinuousClock.now
        let result = await Task.detached(priority: .userInitiated) {
            AlbumFetcher.fetchAlbums()
        }.value
        albums = result
        hasLoadedAlbums = true
        AlbumLoopLog.library.info(
            "Loaded \(result.count) albums in \(String(describing: ContinuousClock.now - start), privacy: .public)"
        )
    }

    /// Snapshot of the album's eligible still-photo identifiers, in playback order.
    /// Returns nil if the album no longer exists.
    func assetIDs(forAlbum albumID: String, order: AlbumOrder) async -> [AssetID]? {
        await Task.detached(priority: .userInitiated) {
            AlbumFetcher.assetIDs(albumID: albumID, order: order)
        }.value
    }

    private func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        let library = PHPhotoLibrary.shared()
        library.register(observer as any PHPhotoLibraryChangeObserver)
        library.register(observer as any PHPhotoLibraryAvailabilityObserver)
        if let reason = library.unavailabilityReason {
            access = .unavailable(reason.localizedDescription)
        }
    }

    private func libraryDidChange() {
        // iCloud sync can deliver bursts of changes; coalesce them.
        changeDebounce?.cancel()
        changeDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.libraryRevision += 1
            AlbumLoopLog.library.info("Photo library changed (revision \(self.libraryRevision))")
            await self.loadAlbums()
        }
    }

    private static func map(_ status: PHAuthorizationStatus) -> Access {
        switch status {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .limited: .limited
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }
}

/// Receives PhotoKit notifications on PhotoKit's background queue.
private final class LibraryObserver: NSObject, PHPhotoLibraryChangeObserver, PHPhotoLibraryAvailabilityObserver,
    @unchecked Sendable {
    // Set once during init on the main actor, before registration; read-only afterwards.
    var onChange: (@Sendable () -> Void)?
    var onUnavailable: (@Sendable (String) -> Void)?

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange?()
    }

    func photoLibraryDidBecomeUnavailable(_ photoLibrary: PHPhotoLibrary) {
        let reason = photoLibrary.unavailabilityReason?.localizedDescription ?? "The photo library is unavailable."
        onUnavailable?(reason)
    }
}

/// Synchronous PhotoKit fetches, run off the main actor.
enum AlbumFetcher {
    static func fetchAlbums() -> [AlbumSummary] {
        // Ordinary user albums only (includes albums inside folders). Shared
        // albums use a different subtype and are intentionally excluded.
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        let photosOnly = PHFetchOptions()
        photosOnly.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

        var albums: [AlbumSummary] = []
        collections.enumerateObjects { collection, _, _ in
            let photos = PHAsset.fetchAssets(in: collection, options: photosOnly)
            let keyAsset = PHAsset.fetchKeyAssets(in: collection, options: photosOnly)?.firstObject ?? photos.firstObject
            albums.append(AlbumSummary(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? "Untitled Album",
                photoCount: photos.count,
                keyAssetID: keyAsset?.localIdentifier
            ))
        }
        return albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func assetIDs(albumID: String, order: AlbumOrder) -> [AssetID]? {
        guard let collection = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumID],
            options: nil
        ).firstObject else {
            return nil
        }
        let options = PHFetchOptions()
        switch order {
        case .album:
            // No sort descriptors and no predicate, so PhotoKit's album order is
            // untouched; videos are filtered out below instead.
            break
        case .oldestFirst:
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        case .newestFirst:
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        }
        let assets = PHAsset.fetchAssets(in: collection, options: options)
        var ids: [AssetID] = []
        ids.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            if asset.mediaType == .image {
                ids.append(AssetID(asset.localIdentifier))
            }
        }
        return ids
    }
}
