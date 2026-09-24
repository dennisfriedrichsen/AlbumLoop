import AlbumLoopCore
import SwiftUI
import UIKit

/// Owns one slideshow session: snapshots the album, creates the controller,
/// and connects it to app lifecycle, network, memory, and library changes.
struct SlideshowScreen: View {
    let album: AlbumSummary
    let order: AlbumOrder
    let settings: SlideshowSettings
    let style: VerticalPhotoStyle

    @Environment(PhotoLibraryModel.self) private var library
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
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            controller?.handleMemoryPressure()
        }
        .onDisappear {
            library.defersAlbumRescans = false
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
        controller.start(assetIDs: snapshot.ids, pairable: pairable(snapshot))
        AlbumLoopLog.playback.info(
            "Display target \(size.width)×\(size.height) px, style \(style.rawValue, privacy: .public), \(snapshot.verticalIDs.count) vertical photos"
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

    private func exit() {
        controller?.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        dismiss()
    }
}
