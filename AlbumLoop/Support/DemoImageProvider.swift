#if DEBUG
import AlbumLoopCore
import UIKit

/// DEBUG-only synthetic image source for checking the slideshow UI in the
/// simulator, which has no iCloud Photos library. Launch with `-demoSlideshow`
/// (and optionally `-verticalStyle slowPan` etc.). Images are numbered cards
/// generated in memory with random delays; every 7th photo fails so the stall
/// panel can be exercised. Two of every three photos are vertical, with the
/// number in the upper third as the "subject".
final class DemoImageProvider: ImageProviding {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-demoSlideshow")
    static let count = 60

    private let style: VerticalPhotoStyle

    init(style: VerticalPhotoStyle) {
        self.style = style
    }

    static func snapshot() -> AlbumSnapshot {
        let ids = (1...count).map { AssetID("demo-\($0)") }
        let vertical = Set((1...count).filter(isVertical).map { AssetID("demo-\($0)") })
        return AlbumSnapshot(ids: ids, verticalIDs: vertical)
    }

    private static func isVertical(_ number: Int) -> Bool {
        number % 3 != 0
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
        let vertical = Self.isVertical(number)
        let size = vertical ? CGSize(width: 1080, height: 1920) : CGSize(width: 1920, height: 1080)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            // Vertical gradient so panning and cropping are visible.
            let top = UIColor(hue: CGFloat(number % 12) / 12, saturation: 0.55, brightness: 0.75, alpha: 1)
            let bottom = UIColor(hue: CGFloat(number % 12) / 12, saturation: 0.7, brightness: 0.25, alpha: 1)
            let colors = [top.cgColor, bottom.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            let text = "\(number)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 360, weight: .bold),
                .foregroundColor: UIColor.white,
            ]
            let textSize = text.size(withAttributes: attributes)
            let centerY = vertical ? size.height * 0.28 : size.height / 2
            text.draw(
                at: CGPoint(x: (size.width - textSize.width) / 2, y: centerY - textSize.height / 2),
                withAttributes: attributes
            )
        }
        return try await SlideRenderer.render(image, style: style, screen: targetPixelSize)
    }
}
#endif
