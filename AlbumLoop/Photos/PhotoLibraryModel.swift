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
    /// Cover photo: the album's key photo in Photos once known, otherwise its
    /// first still photo as a stand-in.
    var keyAssetID: String?
}

/// A folder of albums (and other folders) as organized in Photos.
struct AlbumFolder: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    var items: [LibraryItem]
}

/// One entry in the album browser: an album, or a folder that opens its own grid.
enum LibraryItem: Identifiable, Hashable, Sendable {
    case album(id: String)
    case folder(id: String)

    var id: String {
        switch self {
        case .album(let id): "album:\(id)"
        case .folder(let id): "folder:\(id)"
        }
    }
}

/// Albums and the folder tree they're arranged in.
struct AlbumListing: Sendable {
    var albums: [AlbumSummary]
    /// Items at the top level of My Albums.
    var rootItems: [LibraryItem]
    /// Every non-empty folder, by identifier.
    var folders: [String: AlbumFolder]
}

/// Snapshot of an album's eligible photos taken when a slideshow starts.
struct AlbumSnapshot: Sendable {
    /// Still photos in playback order.
    let ids: [AssetID]
    /// Photos whose stored dimensions are vertical, used for side-by-side pairing.
    let verticalIDs: Set<AssetID>
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
    private(set) var albums: [AlbumSummary] = [] {
        didSet { albumIndex = Dictionary(albums.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first }) }
    }
    /// Top level of the folder tree, as in My Albums in Photos.
    private(set) var rootItems: [LibraryItem] = []
    private(set) var folders: [String: AlbumFolder] = [:]
    private var albumIndex: [String: Int] = [:]
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
            guard !defersAlbumRescans else { return }
            if rescanPending {
                rescanPending = false
                Task { await loadAlbums() }
            } else if !pendingKeyPhotoIDs.isEmpty {
                refreshKeyPhotos(albumIDs: pendingKeyPhotoIDs)
            }
        }
    }

    private let observer = LibraryObserver()
    private var isObserving = false
    private var changeDebounce: Task<Void, Never>?
    private var rescanPending = false

    /// Key photos by album identifier, persisted so covers are right from launch.
    private var keyPhotos = KeyPhotoStore.load()
    private var keyPhotoTask: Task<Void, Never>?
    /// Albums still to check when a key-photo refresh was paused by a slideshow.
    private var pendingKeyPhotoIDs: [String] = []

    /// Albums are counted in batches so the grid fills in progressively.
    private static let countBatchSize = 12
    /// Key photos are slow to fetch (~0.2 s per album on an Apple TV HD), so they're
    /// fetched in small batches after counting, at low priority.
    private static let keyPhotoBatchSize = 6

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
        AlbumLoopLog.library.info("Photos authorization: \(String(describing: self.access))")
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
        keyPhotoTask?.cancel()
        pendingKeyPhotoIDs = []
        let clock = ContinuousClock()
        let start = clock.now

        let listing = await BlockingWork.run {
            AlbumFetcher.fetchAlbumList()
        }
        let listed = listing.albums
        // Forget key photos of albums that no longer exist.
        let listedIDs = Set(listed.map(\.id))
        if keyPhotos.keys.contains(where: { !listedIDs.contains($0) }) {
            keyPhotos = keyPhotos.filter { listedIDs.contains($0.key) }
            KeyPhotoStore.save(keyPhotos)
        }
        // Keep counts from a previous scan so a rescan doesn't blank the grid,
        // and show saved key photos straight away.
        let previous = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var merged = listed
        for index in merged.indices {
            let id = merged[index].id
            merged[index].photoCount = previous[id]?.photoCount
            merged[index].keyAssetID = keyPhotos[id] ?? previous[id]?.keyAssetID
        }
        albums = merged
        rootItems = listing.rootItems
        folders = listing.folders
        countedAlbums = 0
        hasLoadedAlbums = true
        let listedAt = clock.now
        AlbumLoopLog.library.info(
            "Listed \(listed.count) albums in \(String(describing: listedAt - start))"
        )

        var timing = AlbumFetcher.Timing()
        let ids = listed.map(\.id)
        for batchStart in stride(from: 0, to: ids.count, by: Self.countBatchSize) {
            let batch = Array(ids[batchStart..<min(batchStart + Self.countBatchSize, ids.count)])
            // Albums with a saved key photo don't need a stand-in cover.
            let needsCover = Set(batch.filter { keyPhotos[$0] == nil })
            let (details, batchTiming) = await BlockingWork.run {
                AlbumFetcher.fetchDetails(albumIDs: batch, coverFor: needsCover)
            }
            timing.add(batchTiming)
            // Assign once per batch so observers (and the index) update once.
            var updated = albums
            for index in updated.indices {
                let id = updated[index].id
                if let detail = details[id] {
                    updated[index].photoCount = detail.count
                    if keyPhotos[id] == nil {
                        updated[index].keyAssetID = detail.keyAssetID
                    }
                }
            }
            albums = updated
            countedAlbums = min(ids.count, batchStart + batch.count)
        }

        AlbumLoopLog.library.info(
            "Counted \(ids.count) albums in \(String(describing: clock.now - listedAt)) (counting \(String(describing: timing.counting)), covers \(String(describing: timing.keyAssets)))"
        )
        isLoadingAlbums = false
        if rescanPending && !defersAlbumRescans {
            rescanPending = false
            await loadAlbums()
            return
        }
        refreshKeyPhotos(albumIDs: ids)
    }

    /// Replaces stand-in covers with each album's key photo from Photos, in display
    /// order, and saves them. Runs after counting; pauses during a slideshow so it
    /// doesn't compete with photo downloads, and resumes when the slideshow ends.
    private func refreshKeyPhotos(albumIDs: [String]) {
        keyPhotoTask?.cancel()
        pendingKeyPhotoIDs = []
        keyPhotoTask = Task { [weak self] in
            let clock = ContinuousClock()
            let start = clock.now
            var changed = 0
            for batchStart in stride(from: 0, to: albumIDs.count, by: Self.keyPhotoBatchSize) {
                guard let self, !Task.isCancelled else { return }
                if self.defersAlbumRescans {
                    self.pendingKeyPhotoIDs = Array(albumIDs[batchStart...])
                    AlbumLoopLog.library.info("Key photos paused with \(self.pendingKeyPhotoIDs.count) albums left")
                    return
                }
                let batch = Array(albumIDs[batchStart..<min(batchStart + Self.keyPhotoBatchSize, albumIDs.count)])
                let results = await BlockingWork.run(qos: .utility) {
                    AlbumFetcher.fetchKeyPhotos(albumIDs: batch)
                }
                guard !Task.isCancelled else { return }
                changed += self.apply(keyPhotos: results)
            }
            AlbumLoopLog.library.info(
                "Checked key photos for \(albumIDs.count) albums in \(String(describing: clock.now - start)) (\(changed) changed)"
            )
        }
    }

    /// Stores fetched key photos and updates covers. Returns how many covers changed.
    private func apply(keyPhotos results: [String: String?]) -> Int {
        var saved = keyPhotos
        for (albumID, keyID) in results {
            saved[albumID] = keyID
        }
        if saved != keyPhotos {
            keyPhotos = saved
            KeyPhotoStore.save(saved)
        }
        var updated = albums
        var changed = 0
        for index in updated.indices {
            let id = updated[index].id
            guard let result = results[id] else { continue }
            // Without a key photo the stand-in stays, unless the album is now empty.
            let cover = result ?? (updated[index].photoCount == 0 ? nil : updated[index].keyAssetID)
            if updated[index].keyAssetID != cover {
                updated[index].keyAssetID = cover
                changed += 1
            }
        }
        if changed > 0 {
            albums = updated
        }
        return changed
    }

    func album(id: String) -> AlbumSummary? {
        albumIndex[id].map { albums[$0] }
    }

    /// Every album inside the folder, including those in subfolders.
    func albums(inFolder folderID: String) -> [AlbumSummary] {
        guard let folder = folders[folderID] else { return [] }
        return folder.items.flatMap { item -> [AlbumSummary] in
            switch item {
            case .album(let id): album(id: id).map { [$0] } ?? []
            case .folder(let id): albums(inFolder: id)
            }
        }
    }

    /// Snapshot of the album's eligible still photos, in playback order.
    /// Returns nil if the album no longer exists.
    func snapshot(forAlbum albumID: String, order: AlbumOrder) async -> AlbumSnapshot? {
        await BlockingWork.run {
            AlbumFetcher.snapshot(albumID: albumID, order: order)
        }
    }

    func assetIDs(forAlbum albumID: String, order: AlbumOrder) async -> [AssetID]? {
        await snapshot(forAlbum: albumID, order: order)?.ids
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

/// Saved key-photo identifiers by album identifier. Only local identifiers are
/// stored; the thumbnails themselves come from PhotoKit's own cache.
enum KeyPhotoStore {
    private static let key = "albumKeyPhotos"

    static func load() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func save(_ keyPhotos: [String: String]) {
        UserDefaults.standard.set(keyPhotos, forKey: key)
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

    /// Album identifiers, titles, and the folder tree (fast). Counts are filled in separately.
    static func fetchAlbumList() -> AlbumListing {
        // Ordinary user albums only. Shared albums use a different subtype and
        // are intentionally excluded.
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
        // Fallback order for albums the folder walk doesn't reach.
        albums.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        // Walk the folders in My Albums so the browser mirrors them. With no
        // sort descriptors PhotoKit returns each level in the custom order set
        // in Photos. Apple doesn't document this, so check it on a device.
        let albumIDs = Set(albums.map(\.id))
        var folders: [String: AlbumFolder] = [:]
        var placed: Set<String> = []
        var order: [String] = []
        var visited: Set<String> = []
        var rootItems = items(
            in: PHCollectionList.fetchTopLevelUserCollections(with: nil),
            albumIDs: albumIDs,
            folders: &folders,
            placed: &placed,
            order: &order,
            visited: &visited
        )
        // Anything the folder walk didn't reach still appears at the top level.
        for album in albums where !placed.contains(album.id) {
            rootItems.append(.album(id: album.id))
        }
        // Count albums in the order they're shown, so visible cards fill in first.
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        albums.sort { lhs, rhs in
            let (l, r) = (position[lhs.id] ?? .max, position[rhs.id] ?? .max)
            if l != r { return l < r }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        return AlbumListing(albums: albums, rootItems: rootItems, folders: folders)
    }

    /// Albums and non-empty folders in one level of the tree, recursing into folders.
    private static func items(
        in collections: PHFetchResult<PHCollection>,
        albumIDs: Set<String>,
        folders: inout [String: AlbumFolder],
        placed: inout Set<String>,
        order: inout [String],
        visited: inout Set<String>
    ) -> [LibraryItem] {
        var result: [LibraryItem] = []
        for index in 0..<collections.count {
            let collection = collections.object(at: index)
            let id = collection.localIdentifier
            if collection is PHAssetCollection {
                if albumIDs.contains(id), placed.insert(id).inserted {
                    order.append(id)
                    result.append(.album(id: id))
                }
            } else if let list = collection as? PHCollectionList, visited.insert(id).inserted {
                let children = items(
                    in: PHCollection.fetchCollections(in: list, options: nil),
                    albumIDs: albumIDs,
                    folders: &folders,
                    placed: &placed,
                    order: &order,
                    visited: &visited
                )
                // Folders holding only shared albums or empty folders are skipped.
                guard !children.isEmpty else { continue }
                folders[id] = AlbumFolder(id: id, title: list.localizedTitle ?? "Untitled Folder", items: children)
                result.append(.folder(id: id))
            }
        }
        return result
    }

    /// Eligible still-photo count for each album, plus a stand-in cover (its first
    /// still photo) for the albums in `coverFor`.
    ///
    /// Measured on an Apple TV HD with 157 albums: an unfiltered fetch plus
    /// `countOfAssets(with: .image)` took ~4 s in total, versus 20–32 s for a fetch
    /// with a `mediaType` predicate (same counts), and `fetchKeyAssets` took 20–34 s
    /// versus ~3 s for using the album's first photo as its cover. Key photos are
    /// therefore fetched afterwards by `fetchKeyPhotos` and saved between launches.
    static func fetchDetails(albumIDs: [String], coverFor: Set<String>) -> ([String: Detail], Timing) {
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
            if count > 0, coverFor.contains(collection.localIdentifier) {
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

    /// Each album's key photo as chosen in Photos, or nil when it has none.
    /// Albums that no longer exist are left out.
    static func fetchKeyPhotos(albumIDs: [String]) -> [String: String?] {
        let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: albumIDs, options: nil)
        var result: [String: String?] = [:]
        collections.enumerateObjects { collection, _, _ in
            let key = PHAsset.fetchKeyAssets(in: collection, options: nil)?.firstObject
            result[collection.localIdentifier] = .some(key?.localIdentifier)
        }
        return result
    }

    static func snapshot(albumID: String, order: AlbumOrder) -> AlbumSnapshot? {
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
        var vertical: Set<AssetID> = []
        ids.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .image else { return }
            let id = AssetID(asset.localIdentifier)
            ids.append(id)
            // Metadata only; nothing is downloaded.
            if SlideRenderer.isVertical(width: asset.pixelWidth, height: asset.pixelHeight) {
                vertical.insert(id)
            }
        }
        return AlbumSnapshot(ids: ids, verticalIDs: vertical)
    }
}
