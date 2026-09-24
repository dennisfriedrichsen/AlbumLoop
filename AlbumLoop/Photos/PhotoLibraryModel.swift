import AlbumLoopCore
import Observation
import Photos

/// An ordinary (non-shared) Photos album and its eligible still-photo count.
struct AlbumSummary: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    /// Still photos (including Live Photos, shown as stills). Videos are excluded.
    /// Nil while the album is still being counted.
    var photoCount: Int?
    var keyAssetID: String?
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
    /// Albums whose photo count is known during the current scan.
    private(set) var countedAlbums = 0
    /// Incremented (debounced) whenever the photo library changes.
    private(set) var libraryRevision = 0
    /// While true (during a slideshow), library changes don't trigger a full album
    /// rescan; one runs when the slideshow ends. The slideshow still sees
    /// `libraryRevision` change so it can re-snapshot its own album.
    var defersAlbumRescans = false {
        didSet {
            if !defersAlbumRescans, rescanPending {
                rescanPending = false
                Task { await loadAlbums() }
            }
        }
    }

    private let observer = LibraryObserver()
    private var isObserving = false
    private var changeDebounce: Task<Void, Never>?
    private var rescanPending = false

    /// Albums are counted in batches so the grid fills in progressively.
    private static let countBatchSize = 12

    /// Set once the user has pressed Continue on the explanation screen.
    ///
    /// On tvOS 26 (seen on the 26.5 simulator), merely calling
    /// `authorizationStatus(for:)` while the status is undetermined shows the
    /// system prompt, which would cover the explanation screen at launch. Until
    /// the user asks, the app therefore assumes "not determined" without querying.
    private static let hasRequestedAccessKey = "hasRequestedPhotosAccess"
    private var hasRequestedAccess: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hasRequestedAccessKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hasRequestedAccessKey) }
    }

    init() {
        access = UserDefaults.standard.bool(forKey: Self.hasRequestedAccessKey)
            ? Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
            : .notDetermined
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
        hasRequestedAccess = true
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        access = Self.map(status)
        AlbumLoopLog.library.info("Photos authorization: \(String(describing: self.access), privacy: .public)")
        if access == .authorized || access == .limited {
            startObserving()
        }
    }

    /// Re-reads the authorization state, e.g. when returning from Settings.
    func refreshAccess() {
        guard hasRequestedAccess else { return }
        let updated = Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        if case .unavailable = access, updated == .authorized { return }
        access = updated
        if access == .authorized || access == .limited {
            startObserving()
        }
    }

    /// Lists albums immediately, then fills in photo counts and covers in batches.
    /// Concurrent calls are coalesced into one follow-up scan.
    func loadAlbums() async {
        guard access == .authorized || access == .limited else { return }
        guard !isLoadingAlbums else {
            rescanPending = true
            return
        }
        isLoadingAlbums = true
        let clock = ContinuousClock()
        let start = clock.now

        let listed = await Task.detached(priority: .userInitiated) {
            AlbumFetcher.fetchAlbumList()
        }.value
        // Keep counts from a previous scan so a rescan doesn't blank the grid.
        let previous = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        albums = listed.map { album in
            var album = album
            album.photoCount = previous[album.id]?.photoCount
            album.keyAssetID = previous[album.id]?.keyAssetID
            return album
        }
        countedAlbums = 0
        hasLoadedAlbums = true
        let listedAt = clock.now
        AlbumLoopLog.library.info(
            "Listed \(listed.count) albums in \(String(describing: listedAt - start), privacy: .public)"
        )

        var timing = AlbumFetcher.Timing()
        let ids = listed.map(\.id)
        for batchStart in stride(from: 0, to: ids.count, by: Self.countBatchSize) {
            let batch = Array(ids[batchStart..<min(batchStart + Self.countBatchSize, ids.count)])
            let (details, batchTiming) = await Task.detached(priority: .userInitiated) {
                AlbumFetcher.fetchDetails(albumIDs: batch)
            }.value
            timing.add(batchTiming)
            for index in albums.indices {
                if let detail = details[albums[index].id] {
                    albums[index].photoCount = detail.count
                    albums[index].keyAssetID = detail.keyAssetID
                }
            }
            countedAlbums = min(ids.count, batchStart + batch.count)
        }

        AlbumLoopLog.library.info(
            "Counted \(ids.count) albums in \(String(describing: clock.now - listedAt), privacy: .public) (counting \(String(describing: timing.counting), privacy: .public), covers \(String(describing: timing.keyAssets), privacy: .public))"
        )
        isLoadingAlbums = false
        if rescanPending && !defersAlbumRescans {
            rescanPending = false
            await loadAlbums()
        }
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
        // iCloud sync delivers frequent bursts of changes, and a full rescan of a
        // large library takes tens of seconds on older Apple TVs; coalesce them.
        changeDebounce?.cancel()
        changeDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            self.libraryRevision += 1
            AlbumLoopLog.library.info("Photo library changed (revision \(self.libraryRevision))")
            if self.defersAlbumRescans {
                self.rescanPending = true
            } else {
                await self.loadAlbums()
            }
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
    struct Detail: Sendable {
        let count: Int
        let keyAssetID: String?
    }

    struct Timing: Sendable {
        var counting: Duration = .zero
        var keyAssets: Duration = .zero

        mutating func add(_ other: Timing) {
            counting += other.counting
            keyAssets += other.keyAssets
        }
    }

    /// Album identifiers and titles only (fast). Counts are filled in separately.
    static func fetchAlbumList() -> [AlbumSummary] {
        // Ordinary user albums only (includes albums inside folders). Shared
        // albums use a different subtype and are intentionally excluded.
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var albums: [AlbumSummary] = []
        collections.enumerateObjects { collection, _, _ in
            albums.append(AlbumSummary(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? "Untitled Album",
                photoCount: nil,
                keyAssetID: nil
            ))
        }
        return albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Eligible still-photo count and cover photo for each album.
    ///
    /// Measured on an Apple TV HD with 157 albums: an unfiltered fetch plus
    /// `countOfAssets(with: .image)` took ~4 s in total, versus 20–32 s for a fetch
    /// with a `mediaType` predicate (same counts), and `fetchKeyAssets` took 20–34 s
    /// versus ~3 s for using the album's first photo as its cover.
    static func fetchDetails(albumIDs: [String]) -> ([String: Detail], Timing) {
        let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: albumIDs, options: nil)
        let clock = ContinuousClock()
        var timing = Timing()
        var details: [String: Detail] = [:]
        collections.enumerateObjects { collection, _, _ in
            let countStart = clock.now
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            let count = assets.countOfAssets(with: .image)
            let coverStart = clock.now
            timing.counting += coverStart - countStart
            var cover: String?
            if count > 0 {
                // First still photo in album order (usually the very first item).
                assets.enumerateObjects { asset, _, stop in
                    if asset.mediaType == .image {
                        cover = asset.localIdentifier
                        stop.pointee = true
                    }
                }
            }
            timing.keyAssets += clock.now - coverStart
            details[collection.localIdentifier] = Detail(count: count, keyAssetID: cover)
        }
        return (details, timing)
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
