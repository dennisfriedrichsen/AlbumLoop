import AlbumLoopCore
import Network
import Observation
import SwiftUI
import UIKit

/// Tracks whether any network path is available.
@MainActor
@Observable
final class NetworkMonitor {
    private(set) var isAvailable = true
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.isAvailable != available else { return }
                self.isAvailable = available
                AlbumLoopLog.playback.info("Network available: \(available)")
            }
        }
        monitor.start(queue: DispatchQueue(label: "AlbumLoop.NetworkMonitor"))
    }

    func stop() {
        monitor.cancel()
    }
}

enum DisplayMetrics {
    /// The display's native size in pixels (e.g. 3840×2160 on a 4K TV), so
    /// images are requested at screen resolution rather than camera original.
    @MainActor
    static func targetPixelSize() -> PixelSize {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let bounds = scene?.screen.nativeBounds ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let long = max(bounds.width, bounds.height)
        let short = min(bounds.width, bounds.height)
        return PixelSize(width: Int(max(long, 1920)), height: Int(max(short, 1080)))
    }

    /// Buffer sizing per presentation style. The byte budget covers the images
    /// wanted at once (needed + on screen + ahead + behind) at their largest size.
    @MainActor
    static func bufferConfiguration(for size: PixelSize, style: VerticalPhotoStyle) -> ImageBuffer.Configuration {
        var configuration = ImageBuffer.Configuration()
        configuration.maxConcurrentLoads = 2
        // Look-ahead covers slow or retried downloads: 6 photos is ~48 s of slides
        // at 8 s each (~83 MB at 1080p). Measured median download on an Apple TV HD: 0.8 s.
        switch style {
        case .slowPan:
            // Pan images are up to twice screen width tall (~30 MB at 1080p), so hold fewer.
            configuration.prefetchAhead = 3
            configuration.keepBehind = 1
        case .sideBySide:
            // Two photos per slide: 8 photos is about 4 slides.
            configuration.prefetchAhead = 8
            configuration.keepBehind = 2
        case .blurredBackground, .smartCrop, .blackBars:
            configuration.prefetchAhead = 6
            configuration.keepBehind = 2
        }
        let perImage = SlideRenderer.estimatedImageBytes(style: style, screen: size)
        configuration.estimatedImageBytes = perImage
        let wanted = configuration.prefetchAhead + configuration.keepBehind + (style == .sideBySide ? 4 : 2)
        configuration.maxDecodedBytes = perImage * wanted
        return configuration
    }
}

/// Persisted slideshow preferences.
enum SettingsKey {
    static let slideSeconds = "slideSeconds"
    static let shuffle = "shuffle"
    static let loop = "loop"
    static let showCounter = "showCounter"
    static let albumOrder = "albumOrder"
    static let showDiagnostics = "showDiagnostics"
    static let verticalStyle = "verticalStyle"
}

enum SettingsDefault {
    static let slideSeconds = 8
    static let durations = [3, 5, 8, 10, 15, 20, 30, 60]
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }
}
