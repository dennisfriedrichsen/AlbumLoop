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

    func loadImage(
        for id: AssetID,
        targetPixelSize: PixelSize,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> LoadedImage {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id.rawValue], options: nil).firstObject else {
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

        let target = CGSize(width: targetPixelSize.width, height: targetPixelSize.height)
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
        return try await Self.render(image, fitting: targetPixelSize)
    }

    /// Decodes, orients, and downsamples an image so it fits the display.
    /// Rendering into an 8-bit sRGB bitmap forces decoding now (not during
    /// display) and bounds memory to at most the screen's pixel count.
    @concurrent
    private static func render(_ image: UIImage, fitting bounds: PixelSize) async throws -> LoadedImage {
        let source = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard source.width >= 1, source.height >= 1 else {
            throw ImageLoadFailure(.decodeFailed, "The photo has no pixels.")
        }
        let scale = min(1, CGFloat(bounds.width) / source.width, CGFloat(bounds.height) / source.height)
        let size = CGSize(width: max(1, (source.width * scale).rounded()), height: max(1, (source.height * scale).rounded()))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let cgImage = rendered.cgImage else {
            throw ImageLoadFailure(.decodeFailed, "The photo could not be decoded.")
        }
        return LoadedImage(cgImage: cgImage)
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
