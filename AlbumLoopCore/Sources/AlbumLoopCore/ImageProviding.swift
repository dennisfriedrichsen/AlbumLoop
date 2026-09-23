import CoreGraphics
import Foundation

/// Stable identifier of a photo in the library (a PhotoKit `localIdentifier` in the app).
public struct AssetID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    /// Short, non-reversible token for logs. Never log image contents or raw identifiers.
    public var logToken: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in rawValue.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return String(hash & 0xffff_ffff, radix: 16)
    }
}

/// A size in physical pixels (not points).
public struct PixelSize: Hashable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// Upper bound for the decoded size of one image fitted into this size (32-bit RGBA).
    public var decodedByteEstimate: Int { max(1, width) * max(1, height) * 4 }
}

/// A fully decoded image ready for display, sized for the screen.
public struct LoadedImage: @unchecked Sendable {
    // CGImage is immutable; the wrapper is safe to pass between isolation domains.
    public let cgImage: CGImage?
    public let pixelSize: PixelSize
    public let byteCost: Int

    public init(cgImage: CGImage) {
        self.cgImage = cgImage
        self.pixelSize = PixelSize(width: cgImage.width, height: cgImage.height)
        self.byteCost = cgImage.bytesPerRow * cgImage.height
    }

    /// Image-less value for tests and diagnostics.
    public init(placeholderPixelSize: PixelSize, byteCost: Int) {
        self.cgImage = nil
        self.pixelSize = placeholderPixelSize
        self.byteCost = byteCost
    }
}

/// Why an image could not be loaded.
public struct ImageLoadFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable {
        /// The asset no longer exists (deleted or removed from the library). Not retried.
        case notFound
        /// The asset is not a still photo. Not retried.
        case unsupported
        /// A network or iCloud error was reported.
        case network
        /// No download progress arrived within the stall timeout.
        case stalled
        /// The attempt exceeded its hard time limit.
        case timedOut
        /// The image data could not be decoded or rendered.
        case decodeFailed
        /// Any other error reported by the image source.
        case other
    }

    public var kind: Kind
    public var message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var isRetryable: Bool {
        switch kind {
        case .notFound, .unsupported: false
        case .network, .stalled, .timedOut, .decodeFailed, .other: true
        }
    }

    public var description: String { "\(kind.rawValue): \(message)" }
}

/// Source of display-ready images. The app implements this with PhotoKit;
/// tests use a fake whose requests complete on demand.
public protocol ImageProviding: Sendable {
    /// Loads one image sized to fit within `targetPixelSize`.
    ///
    /// - Returns only a final, acceptable image (never a degraded preview).
    /// - Throws `ImageLoadFailure` for load problems, or `CancellationError`
    ///   when the calling task is cancelled.
    /// - `progress` may be called from any thread with values in 0...1.
    func loadImage(
        for id: AssetID,
        targetPixelSize: PixelSize,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> LoadedImage
}
