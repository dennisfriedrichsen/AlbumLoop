import StillroomCore
import SwiftUI
import UIKit

/// Owns one slideshow session: snapshots the album, creates the controller,
/// and connects it to app lifecycle, network, memory, and library changes.
struct SlideshowScreen: View {
    let album: AlbumSummary
    let order: AlbumOrder
    let settings: SlideshowSettings
    let style: VerticalPhotoStyle
    /// Where to pick up a slideshow that was left part way through.
    var resume: ResumePoint?

    @Environment(PhotoLibraryModel.self) private var library
    @Environment(RecentPlaybackStore.self) private var recents
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller: SlideshowController?
    @State private var network = NetworkMonitor()
    @State private var preparationError: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let controller {
                SlideshowView(
                    controller: controller,
                    albumTitle: album.title,
                    style: style,
                    isNetworkAvailable: network.isAvailable,
                    onExit: exit,
                    onRestart: restart
                )
            } else if let preparationError {
                StatusMessageView(systemImage: "exclamationmark.triangle", title: "Can’t Start", message: preparationError) {
                    Button("Done", action: exit)
                }
            } else {
                ProgressView("Preparing “\(album.title)”…")
            }
        }
        .task { await prepare() }
        .onAppear { library.defersAlbumRescans = true }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: controller?.enterForeground()
            case .background: controller?.enterBackground()
            case .inactive: break
            @unknown default: break
            }
            updateIdleTimer()
        }
        .onChange(of: network.isAvailable) { _, available in
            controller?.networkAvailabilityChanged(available)
        }
        .onChange(of: library.libraryRevision) {
            Task { await albumMayHaveChanged() }
        }
        .onChange(of: controller?.wantsDisplayAwake ?? false, initial: true) {
            updateIdleTimer()
        }
        .onChange(of: controller?.targetPosition) { recordProgress() }
        .onChange(of: controller?.phase) { recordProgress() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            controller?.handleMemoryPressure()
        }
        .onDisappear {
            library.defersAlbumRescans = false
            recordProgress()
            controller?.stop()
            network.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func prepare() async {
        guard controller == nil else { return }
        let provider: any ImageProviding
        #if DEBUG
        provider = DemoImageProvider.isEnabled ? DemoImageProvider(style: style) : PhotoKitImageProvider(style: style)
        #else
        provider = PhotoKitImageProvider(style: style)
        #endif
        guard let snapshot = await takeSnapshot() else {
            preparationError = "This album is no longer in your library."
            return
        }
        let size = DisplayMetrics.targetPixelSize()
        let controller = SlideshowController(
            provider: provider,
            scheduler: ContinuousScheduler(),
            targetPixelSize: size,
            bufferConfiguration: DisplayMetrics.bufferConfiguration(for: size, style: style),
            settings: settings
        )
        controller.networkAvailabilityChanged(network.isAvailable)
        self.controller = controller
        controller.start(
            assetIDs: snapshot.ids,
            pairable: pairable(snapshot),
            resumeAt: resume.map { AssetID($0.assetID) },
            seed: resume?.seed
        )
        recordProgress()
        StillroomLog.playback.info(
            "Display target \(size.width)×\(size.height) px, style \(style.rawValue), \(snapshot.verticalIDs.count) vertical photos"
        )
    }

    /// The album's photos in playback order. Demo mode never touches PhotoKit.
    private func takeSnapshot() async -> AlbumSnapshot? {
        #if DEBUG
        if DemoImageProvider.isEnabled {
            return DemoImageProvider.snapshot()
        }
        #endif
        return await library.snapshot(forAlbum: album.id, order: order)
    }

    private func pairable(_ snapshot: AlbumSnapshot) -> Set<AssetID> {
        style == .sideBySide ? snapshot.verticalIDs : []
    }

    /// Starts again from a fresh album snapshot (after finishing or a fatal error).
    private func restart() {
        Task {
            guard let controller else { return }
            guard let snapshot = await takeSnapshot() else {
                controller.stop()
                preparationError = "This album is no longer in your library."
                self.controller = nil
                return
            }
            controller.start(assetIDs: snapshot.ids, pairable: pairable(snapshot), settings: controller.settings)
        }
    }

    private func albumMayHaveChanged() async {
        guard let controller, let snapshot = await takeSnapshot() else { return }
        controller.albumContentsChanged(snapshot.ids, pairable: pairable(snapshot))
    }

    private func updateIdleTimer() {
        // Keep the TV awake only while a slideshow is actively playing in the foreground.
        let awake = scenePhase == .active && (controller?.wantsDisplayAwake ?? false)
        if UIApplication.shared.isIdleTimerDisabled != awake {
            UIApplication.shared.isIdleTimerDisabled = awake
        }
    }

    /// Saves where playback is so the Recently Played row can resume it.
    /// Called on every slide change, since the app may be terminated in the background.
    private func recordProgress() {
        guard let controller, controller.total > 0 else { return }
        #if DEBUG
        if DemoImageProvider.isEnabled { return }
        #endif
        var point: ResumePoint?
        if controller.phase != .finished, controller.targetPosition > 0, let id = controller.currentTargetID {
            point = ResumePoint(
                assetID: id.rawValue,
                position: controller.targetPosition,
                total: controller.total,
                albumOrder: order,
                shuffled: controller.settings.order == .shuffled,
                seed: controller.seed
            )
        }
        recents.record(albumID: album.id, resume: point)
    }

    private func exit() {
        recordProgress()
        controller?.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        dismiss()
    }
}

/// Starts or resumes an album's slideshow with the saved slideshow settings.
/// A resumed slideshow keeps the order and shuffle it was playing with, so it
/// continues through the same sequence of photos.
struct SlideshowLaunch: View {
    let album: AlbumSummary
    let resume: ResumePoint?

    @AppStorage(SettingsKey.slideSeconds) private var slideSeconds = SettingsDefault.slideSeconds
    @AppStorage(SettingsKey.shuffle) private var shuffle = false
    @AppStorage(SettingsKey.loop) private var loop = true
    @AppStorage(SettingsKey.albumOrder) private var albumOrder = AlbumOrder.album
    @AppStorage(SettingsKey.verticalStyle) private var verticalStyle = VerticalPhotoStyle.recommended

    var body: some View {
        SlideshowScreen(
            album: album,
            order: resume?.albumOrder ?? albumOrder,
            settings: SlideshowSettings(
                slideDuration: .seconds(slideSeconds),
                order: (resume?.shuffled ?? shuffle) ? .shuffled : .sequential,
                loops: loop
            ),
            style: verticalStyle,
            resume: resume
        )
    }
}

/// A request to present a slideshow, for `fullScreenCover(item:)`.
struct SlideshowRequest: Identifiable {
    let id = UUID()
    let album: AlbumSummary
    let resume: ResumePoint?
}

/// The one place slideshows are presented from, so the album screen, the
/// Recently Played row, and Top Shelf links all share a single full-screen cover.
/// Setting a new request while one is showing replaces it.
@MainActor
@Observable
final class PlaybackRouter {
    var request: SlideshowRequest?
}
