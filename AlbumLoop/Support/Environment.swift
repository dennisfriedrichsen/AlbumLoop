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

    /// Buffer sizing: memory for current + on-screen + 3 ahead + 2 behind images at screen size.
    @MainActor
    static func bufferConfiguration(for size: PixelSize) -> ImageBuffer.Configuration {
        var configuration = ImageBuffer.Configuration()
        configuration.prefetchAhead = 3
        configuration.keepBehind = 2
        configuration.maxConcurrentLoads = 2
        configuration.maxDecodedBytes = size.decodedByteEstimate * 7
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
