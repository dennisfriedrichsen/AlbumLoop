import AlbumLoopCore
import Photos
import UIKit

/// Loads slideshow images through public PhotoKit APIs, downloading from
/// iCloud when needed, and returns decoded images no larger than the display.
///
/// Nothing is written to disk by the app. PhotoKit's own caches are system
/// managed and purgeable; the app never relies on them holding anything.
final class PhotoKitImageProvider: ImageProviding {
    private let manager = PHImageManager.default()
    private let style: VerticalPhotoStyle

    init(style: VerticalPhotoStyle) {
        self.style = style
    }

    func loadImage(
        for id: AssetID,
        targetPixelSize: PixelSize,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> LoadedImage {
        let identifier = id.rawValue
        let fetched = await BlockingWork.run {
            UncheckedAsset(asset: PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject)
        }
        guard let asset = fetched.asset else {
            throw ImageLoadFailure(.notFound, "This photo is no longer in the library.")
        }
        guard asset.mediaType == .image else {
            throw ImageLoadFailure(.unsupported, "This item is not a still photo.")
        }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.version = .current
        options.isSynchronous = false
        options.progressHandler = { fraction, error, _, _ in
            // Called on an arbitrary queue while downloading from iCloud.
            if error == nil { progress(fraction) }
        }

        // Vertical photos may need more than screen height for panning or cropping.
        let target = SlideRenderer.requestSize(
            style: style,
            screen: targetPixelSize,
            assetWidth: asset.pixelWidth,
            assetHeight: asset.pixelHeight
        )
        let result = try await PhotoKitRequest.requestImage(
            manager: manager,
            asset: asset,
            targetSize: target,
            contentMode: .aspectFit,
            options: options
        )
        try Task.checkCancellation()

        if let error = result.error {
            throw Self.failure(from: error)
        }
        guard let image = result.image else {
            if result.isInCloud {
                throw ImageLoadFailure(.network, "The photo is stored in iCloud and could not be downloaded.")
            }
            throw ImageLoadFailure(.other, "Photos returned no image.")
        }
        return try await SlideRenderer.render(image, style: style, screen: targetPixelSize)
    }

    static func failure(from error: any Error) -> ImageLoadFailure {
        let nsError = error as NSError
        let detail = "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
        if nsError.domain == NSURLErrorDomain {
            return ImageLoadFailure(.network, detail)
        }
        if nsError.domain == PHPhotosErrorDomain {
            switch PHPhotosError.Code(rawValue: nsError.code) {
            case .networkAccessRequired, .networkError:
                return ImageLoadFailure(.network, detail)
            case .identifierNotFound:
                return ImageLoadFailure(.notFound, detail)
            default:
                return ImageLoadFailure(.other, detail)
            }
        }
        if nsError.domain.localizedCaseInsensitiveContains("cloud") {
            return ImageLoadFailure(.network, detail)
        }
        return ImageLoadFailure(.other, detail)
    }
}

/// PHAsset is an immutable snapshot of metadata; safe to hand across threads.
private struct UncheckedAsset: @unchecked Sendable {
    let asset: PHAsset?
}
