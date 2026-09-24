import AlbumLoopCore
import SwiftUI
import UIKit

/// Owns one slideshow session: snapshots the album, creates the controller,
/// and connects it to app lifecycle, network, memory, and library changes.
struct SlideshowScreen: View {
    let album: AlbumSummary
    let order: AlbumOrder
    let settings: SlideshowSettings

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
        let snapshot: [AssetID]?
        #if DEBUG
        if DemoImageProvider.isEnabled {
            // Never touch PhotoKit in demo mode (it would trigger the permission prompt).
            provider = DemoImageProvider()
            snapshot = DemoImageProvider.ids()
        } else {
            provider = PhotoKitImageProvider()
            snapshot = await library.assetIDs(forAlbum: album.id, order: order)
        }
        #else
        provider = PhotoKitImageProvider()
        snapshot = await library.assetIDs(forAlbum: album.id, order: order)
        #endif
        guard let ids = snapshot else {
            preparationError = "This album is no longer in your library."
            return
        }
        let size = DisplayMetrics.targetPixelSize()
        let controller = SlideshowController(
            provider: provider,
            scheduler: ContinuousScheduler(),
            targetPixelSize: size,
            bufferConfiguration: DisplayMetrics.bufferConfiguration(for: size),
            settings: settings
        )
        controller.networkAvailabilityChanged(network.isAvailable)
        self.controller = controller
        controller.start(assetIDs: ids)
        AlbumLoopLog.playback.info("Display target \(size.width)×\(size.height) px")
    }

    /// Starts again from a fresh album snapshot (after finishing or a fatal error).
    private func restart() {
        Task {
            guard let controller else { return }
            guard let ids = await library.assetIDs(forAlbum: album.id, order: order) else {
                controller.stop()
                preparationError = "This album is no longer in your library."
                self.controller = nil
                return
            }
            controller.start(assetIDs: ids, settings: controller.settings)
        }
    }

    private func albumMayHaveChanged() async {
        guard let controller else { return }
        guard let ids = await library.assetIDs(forAlbum: album.id, order: order) else { return }
        controller.albumContentsChanged(ids)
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
