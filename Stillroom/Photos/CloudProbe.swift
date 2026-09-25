import StillroomCore
import Observation
import Photos
import UIKit

/// On-device check that photos not stored on the Apple TV can be downloaded.
///
/// For a spread of photos across an album it asks PhotoKit for a display-sized
/// image with network access OFF (to see whether it is available locally), then
/// downloads the cloud-only ones with network access ON and times them. The
/// decoded images are discarded immediately.
@MainActor
@Observable
final class CloudProbe {
    struct Row: Identifiable {
        let id: Int
        /// 1-based position in the album.
        let position: Int
        var local: String = "…"
        var download: String = ""
    }

    private(set) var rows: [Row] = []
    private(set) var isRunning = false
    private(set) var summary = ""

    private let manager = PHImageManager.default()

    func run(ids: [AssetID], sampleCount: Int, targetPixelSize: PixelSize) async {
        guard !ids.isEmpty else {
            summary = "This album has no photos."
            return
        }
        isRunning = true
        defer { isRunning = false }
        let count = min(sampleCount, ids.count)
        // Evenly spaced across the album, always including the last photo.
        let positions = (0..<count).map { count == 1 ? ids.count - 1 : $0 * (ids.count - 1) / (count - 1) }
        rows = positions.enumerated().map { Row(id: $0.offset, position: $0.element + 1) }
        summary = "Probing \(count) of \(ids.count) photos…"

        let target = CGSize(width: targetPixelSize.width, height: targetPixelSize.height)
        var localCount = 0
        var cloudOnly = 0
        var downloaded = 0
        var durations: [Duration] = []

        for (index, position) in positions.enumerated() {
            if Task.isCancelled { break }
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [ids[position].rawValue], options: nil).firstObject else {
                rows[index].local = "missing"
                continue
            }
            let localResult = try? await request(asset, target: target, network: false)
            if localResult?.image != nil {
                localCount += 1
                rows[index].local = "on device"
                continue
            }
            cloudOnly += 1
            rows[index].local = (localResult?.isInCloud ?? false) ? "iCloud only" : "not local"
            rows[index].download = "downloading…"

            let clock = ContinuousClock()
            let start = clock.now
            do {
                let result = try await request(asset, target: target, network: true)
                let elapsed = clock.now - start
                if result.image != nil {
                    downloaded += 1
                    durations.append(elapsed)
                    rows[index].download = "✓ \(Self.format(elapsed))"
                } else {
                    let message = result.error.map { PhotoKitImageProvider.failure(from: $0).message } ?? "no image"
                    rows[index].download = "✗ \(message)"
                }
            } catch {
                rows[index].download = "cancelled"
            }
        }

        let sorted = durations.sorted()
        let median = sorted.isEmpty ? "–" : Self.format(sorted[sorted.count / 2])
        let slowest = sorted.last.map(Self.format) ?? "–"
        summary = "\(count) sampled: \(localCount) on device, \(cloudOnly) not on device; "
            + "\(downloaded)/\(cloudOnly) downloaded (median \(median), slowest \(slowest))."
        StillroomLog.loading.info("Cloud probe: \(self.summary)")
    }

    private func request(_ asset: PHAsset, target: CGSize, network: Bool) async throws -> PhotoKitRequest.FinalResult {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = network
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        return try await PhotoKitRequest.requestImage(
            manager: manager,
            asset: asset,
            targetSize: target,
            contentMode: .aspectFit,
            options: options
        )
    }

    private static func format(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.1f s", seconds)
    }
}
