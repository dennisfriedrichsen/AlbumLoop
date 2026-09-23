#if DEBUG
import AlbumLoopCore
import UIKit

/// DEBUG-only synthetic image source for checking the slideshow UI in the
/// simulator, which has no iCloud Photos library. Launch with `-demoSlideshow`.
/// Images are numbered cards generated in memory, with random delays; every
/// 7th photo fails so the stall panel can be exercised.
final class DemoImageProvider: ImageProviding {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-demoSlideshow")

    static func ids(count: Int = 60) -> [AssetID] {
        (1...count).map { AssetID("demo-\($0)") }
    }

    func loadImage(
        for id: AssetID,
        targetPixelSize: PixelSize,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> LoadedImage {
        let number = Int(id.rawValue.split(separator: "-").last ?? "0") ?? 0
        for step in 1...4 {
            try await Task.sleep(for: .milliseconds(Int.random(in: 100...600)))
            progress(Double(step) / 4)
        }
        if number % 7 == 0 {
            throw ImageLoadFailure(.network, "Demo failure for photo \(number).")
        }
        // Alternate landscape and portrait to check aspect-fit letterboxing.
        let portrait = number % 3 == 0
        let size = portrait ? CGSize(width: 1200, height: 1600) : CGSize(width: 1920, height: 1080)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(hue: CGFloat(number % 12) / 12, saturation: 0.5, brightness: 0.55, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let text = "\(number)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 400, weight: .bold),
                .foregroundColor: UIColor.white,
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
                      withAttributes: attributes)
        }
        guard let cgImage = image.cgImage else {
            throw ImageLoadFailure(.decodeFailed, "Demo render failed.")
        }
        return LoadedImage(cgImage: cgImage)
    }
}
#endif
