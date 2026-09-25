import StillroomCore
import SwiftUI

/// Routes between the Photos-access states and the album browser.
struct RootView: View {
    @Environment(PhotoLibraryModel.self) private var library
    @Environment(RecentPlaybackStore.self) private var recents
    @Environment(PlaybackRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    /// Album from a Top Shelf link, held until the album list has loaded.
    @State private var pendingAlbumID: String?

    var body: some View {
        #if DEBUG
        if DemoImageProvider.isEnabled {
            SlideshowScreen(
                album: AlbumSummary(id: "demo", title: "Demo", photoCount: DemoImageProvider.count, keyAssetID: nil),
                order: .album,
                settings: SlideshowSettings(slideDuration: .seconds(6)),
                style: VerticalPhotoStyle(
                    rawValue: UserDefaults.standard.string(forKey: SettingsKey.verticalStyle) ?? ""
                ) ?? .recommended
            )
        } else {
            browser
        }
        #else
        browser
        #endif
    }

    private var browser: some View {
        @Bindable var router = router
        return NavigationStack {
            content
                .navigationDestination(for: AlbumSummary.self) { album in
                    AlbumDetailView(album: album)
                }
                .navigationDestination(for: AppDestination.self) { destination in
                    switch destination {
                    case .about: AboutView()
                    case .folder(let id): AlbumGridView(folderID: id)
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // The user may have changed permission in Settings while away.
            if phase == .active { library.refreshAccess() }
        }
        .fullScreenCover(item: $router.request) { request in
            SlideshowLaunch(album: request.album, resume: request.resume)
        }
        .onOpenURL { url in
            pendingAlbumID = TopShelfFeed.albumID(from: url)
            openPendingAlbum()
        }
        .onChange(of: library.hasLoadedAlbums) { openPendingAlbum() }
        .task(id: TopShelfInputs(recents: recents.items, albums: library.albums)) {
            // Coalesce the saves made on every slide change.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            StillroomLog.library.info("Top Shelf: updating from \(recents.items.count) recent albums")
            await TopShelfPublisher.publish(recents: recents.items, library: library)
        }
    }

    /// Plays (or resumes) the album a Top Shelf item was selected for.
    private func openPendingAlbum() {
        guard let id = pendingAlbumID, library.hasLoadedAlbums else { return }
        pendingAlbumID = nil
        guard let album = library.album(id: id), album.photoCount != 0 else { return }
        router.request = SlideshowRequest(album: album, resume: recents.entry(for: id)?.resume)
    }

    @ViewBuilder
    private var content: some View {
        switch library.access {
        case .notDetermined:
            AccessRequestView()
        case .authorized, .limited:
            AlbumGridView()
        case .denied:
            StatusMessageView(
                systemImage: "lock.fill",
                title: "Photos Access Is Off",
                message: "Stillroom needs permission to read your photo library to show slideshows. "
                    + "Open Settings › General › Privacy & Security › Photos and allow Stillroom, then come back."
            )
        case .restricted:
            StatusMessageView(
                systemImage: "hand.raised.fill",
                title: "Photos Access Is Restricted",
                message: "Access to Photos is restricted on this Apple TV, for example by Screen Time or a device "
                    + "profile. Stillroom can’t change this; someone who manages this Apple TV can."
            )
        case .unavailable(let reason):
            StatusMessageView(
                systemImage: "icloud.slash",
                title: "Photo Library Unavailable",
                message: "\(reason)\n\nMake sure iCloud Photos is turned on in Settings › Users and Accounts "
                    + "› iCloud for the current user, then reopen Stillroom."
            )
        }
    }
}

private struct TopShelfInputs: Hashable {
    let recents: [RecentPlayback]
    let albums: [AlbumSummary]
}

enum AppDestination: Hashable {
    case about
    case folder(id: String)
}

/// First-launch explanation shown before the system permission prompt.
struct AccessRequestView: View {
    @Environment(PhotoLibraryModel.self) private var library

    var body: some View {
        VStack(spacing: 40) {
            Image(systemName: "photo.stack")
                .font(.system(size: 120))
                .foregroundStyle(.secondary)
            Text("Stillroom")
                .font(.largeTitle.bold())
            Text(
                "Stillroom plays slideshows of your Photos albums, including photos that are stored only in iCloud. "
                    + "It needs permission to read your photo library.\n\nPhotos are loaded a few at a time while you "
                    + "watch. Nothing is copied off this Apple TV, saved by the app, or sent anywhere else."
            )
            .multilineTextAlignment(.center)
            .frame(maxWidth: 1100)
            .foregroundStyle(.secondary)
            Button("Continue") {
                Task { await library.requestAccess() }
            }
        }
        .padding(80)
    }
}

/// Full-screen explanation for a state the user has to resolve.
struct StatusMessageView<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 36) {
            Image(systemName: systemImage)
                .font(.system(size: 100))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.bold())
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 1200)
            actions
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension StatusMessageView where Actions == EmptyView {
    init(systemImage: String, title: String, message: String) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}
