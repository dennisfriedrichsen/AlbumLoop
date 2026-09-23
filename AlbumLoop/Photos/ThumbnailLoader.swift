import Photos
import UIKit

/// Loads small album-cover thumbnails, allowing iCloud downloads.
/// Thumbnails live only in a bounded in-memory cache.
@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let manager = PHImageManager.default()
    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 120
        return cache
    }()

    func thumbnail(for assetID: String, pixelSize: CGSize) async -> UIImage? {
        let key = "\(assetID)|\(Int(pixelSize.width))x\(Int(pixelSize.height))" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
            return nil
        }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        guard let result = try? await PhotoKitRequest.requestImage(
            manager: manager,
            asset: asset,
            targetSize: pixelSize,
            contentMode: .aspectFill,
            options: options
        ), let image = result.image else {
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }
}
