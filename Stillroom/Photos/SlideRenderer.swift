import StillroomCore
import CoreImage
import Synchronization
import UIKit
import Vision

/// Immutable images handed to a serial queue; safe to send across isolation.
private struct UncheckedImage: @unchecked Sendable {
    let image: UIImage
}

private struct UncheckedCGImage: @unchecked Sendable {
    let image: CGImage
}

/// How vertical photos (and anything else that doesn't fill a 16:9 screen) are presented.
enum VerticalPhotoStyle: String, CaseIterable, Identifiable, Sendable {
    case blurredBackground
    case slowPan
    case smartCrop
    case sideBySide
    case blackBars

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blurredBackground: "Blurred Background"
        case .slowPan: "Slow Pan"
        case .smartCrop: "Smart Crop"
        case .sideBySide: "Side by Side"
        case .blackBars: "Black Bars"
        }
    }

    var explanation: String {
        switch self {
        case .blurredBackground:
            "The whole photo, with a blurred copy filling the sides. Lightest on older Apple TVs."
        case .slowPan:
            "Vertical photos fill the screen and slowly pan toward the face or subject. Uses the most memory and processing."
        case .smartCrop:
            "Vertical photos fill the screen, cropped around the face or subject. Parts of the photo aren’t shown."
        case .sideBySide:
            "Two vertical photos next to each other share a slide."
        case .blackBars:
            "The whole photo with black bars at the sides."
        }
    }

    /// Photos taller than this width-to-height ratio are treated as vertical.
    static let verticalAspectLimit: CGFloat = 0.9

    /// Best choice for the Apple TV the app is running on.
    static var recommended: VerticalPhotoStyle {
        DeviceClass.current.isOlderModel ? .blurredBackground : .slowPan
    }

    var usesBackdrop: Bool { self != .blackBars }
}

/// Coarse Apple TV hardware classification.
enum DeviceClass {
    case older
    case newer

    /// Apple TV HD (AppleTV5,x) and Apple TV 4K 1st generation (AppleTV6,x)
    /// have A8/A10X chips and stop at tvOS 26.
    var isOlderModel: Bool { self == .older }

    static let current: DeviceClass = {
        let identifier = modelIdentifier
        return identifier.hasPrefix("AppleTV5,") || identifier.hasPrefix("AppleTV6,") ? .older : .newer
    }()

    /// Hardware model such as "AppleTV5,3" (the simulated model in the simulator).
    static var modelIdentifier: String {
        ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machineIdentifier()
    }

    private static func machineIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// Turns a decoded photo into a display-ready `LoadedImage` for a presentation style.
/// Runs off the main actor; every step bounds memory to roughly screen size.
enum SlideRenderer {
    /// Widest image rendered for panning. Keeps a 4K pan image near 50 MB.
    static let maxPanWidth = 2560

    static func isVertical(width: Int, height: Int) -> Bool {
        height > 0 && CGFloat(width) / CGFloat(height) < VerticalPhotoStyle.verticalAspectLimit
    }

    /// Largest decoded size one image can have for a style, for memory budgeting.
    static func estimatedImageBytes(style: VerticalPhotoStyle, screen: PixelSize) -> Int {
        switch style {
        case .slowPan:
            let width = min(screen.width, maxPanWidth)
            return width * width * 2 * 4
        case .blurredBackground, .smartCrop, .sideBySide, .blackBars:
            return screen.decodedByteEstimate
        }
    }

    /// Size to request from PhotoKit so the renderer has enough pixels without asking for the original.
    static func requestSize(style: VerticalPhotoStyle, screen: PixelSize, assetWidth: Int, assetHeight: Int) -> CGSize {
        let screenSize = CGSize(width: screen.width, height: screen.height)
        guard isVertical(width: assetWidth, height: assetHeight), assetWidth > 0 else { return screenSize }
        switch style {
        case .slowPan:
            let width = CGFloat(min(screen.width, maxPanWidth))
            return CGSize(width: width, height: width * CGFloat(assetHeight) / CGFloat(assetWidth))
        case .smartCrop:
            let width = CGFloat(screen.width)
            return CGSize(width: width, height: width * CGFloat(assetHeight) / CGFloat(assetWidth))
        case .blurredBackground, .sideBySide, .blackBars:
            return screenSize
        }
    }

    /// Serial queue for decoding, drawing, and cropping (never the cooperative pool;
    /// see `BlockingWork`).
    private static let renderQueue = DispatchQueue(label: "Stillroom.SlideRenderer", qos: .userInitiated)

    static func render(_ image: UIImage, style: VerticalPhotoStyle, screen: PixelSize) async throws -> LoadedImage {
        let input = UncheckedImage(image: image)
        return try await BlockingWork.run(on: renderQueue) {
            try renderSynchronously(input.image, style: style, screen: screen)
        }
    }

    private static func renderSynchronously(
        _ image: UIImage,
        style: VerticalPhotoStyle,
        screen: PixelSize
    ) throws -> LoadedImage {
        let source = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard source.width >= 1, source.height >= 1 else {
            throw ImageLoadFailure(.decodeFailed, "The photo has no pixels.")
        }
        let vertical = isVertical(width: Int(source.width), height: Int(source.height))

        let main: CGImage
        var focus: CGPoint?
        switch (style, vertical) {
        case (.slowPan, true):
            var width = min(CGFloat(min(screen.width, maxPanWidth)), source.width)
            var height = width * source.height / source.width
            if height > width * 2 {
                height = width * 2
                width = height * source.width / source.height
            }
            main = try draw(image, size: CGSize(width: width, height: height))
            focus = detectFocus(in: main)
        case (.smartCrop, true):
            let width = min(CGFloat(screen.width), source.width)
            let full = try draw(image, size: CGSize(width: width, height: width * source.height / source.width))
            focus = detectFocus(in: full)
            main = try crop(full, toAspect: CGFloat(screen.width) / CGFloat(screen.height), around: focus)
        default:
            let scale = min(1, CGFloat(screen.width) / source.width, CGFloat(screen.height) / source.height)
            main = try draw(image, size: CGSize(width: source.width * scale, height: source.height * scale))
        }
        let backdrop = style.usesBackdrop ? makeBackdrop(from: main) : nil
        return LoadedImage(cgImage: main, backdrop: backdrop, focus: focus)
    }

    // MARK: Steps

    /// Decodes and orients into an opaque 8-bit bitmap of exactly `size` pixels.
    private static func draw(_ image: UIImage, size: CGSize) throws -> CGImage {
        let size = CGSize(width: max(1, size.width.rounded()), height: max(1, size.height.rounded()))
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
        return cgImage
    }

    /// Crops to the screen's aspect ratio, keeping the focus point as central as possible.
    /// Copies into a new bitmap so the larger source can be freed.
    private static func crop(_ image: CGImage, toAspect aspect: CGFloat, around focus: CGPoint?) throws -> CGImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let cropHeight = min(height, (width / aspect).rounded())
        // Without a detected subject, centre on the upper third, where faces usually are.
        let centerY = (focus?.y ?? 0.33) * height
        let top = min(max(0, centerY - cropHeight / 2), height - cropHeight)
        guard let cropped = image.cropping(to: CGRect(x: 0, y: top, width: width, height: cropHeight)) else {
            throw ImageLoadFailure(.decodeFailed, "The photo could not be cropped.")
        }
        return try draw(UIImage(cgImage: cropped), size: CGSize(width: width, height: cropHeight))
    }

    /// Vision runs on its own queue and is given `visionTimeout` to answer.
    private static let visionQueue = DispatchQueue(label: "Stillroom.Vision", qos: .userInitiated)
    private static let visionTimeout: DispatchTimeInterval = .seconds(3)
    /// Set after a Vision request fails to answer in time. A hung request keeps
    /// `visionQueue` busy, so later photos skip detection and use the fallback framing.
    private static let visionDisabled = Mutex(false)

    /// Centre of detected faces, else of the most attention-grabbing region;
    /// normalised with a top-left origin. Returns nil (fallback framing) if Vision
    /// fails, finds nothing, or doesn't answer within `visionTimeout`.
    private static func detectFocus(in image: CGImage) -> CGPoint? {
        guard !visionDisabled.withLock({ $0 }) else { return nil }
        guard let small = try? downscale(image, maxDimension: 512) else { return nil }
        let result = Mutex<CGPoint?>(nil)
        let done = DispatchSemaphore(value: 0)
        let input = UncheckedCGImage(image: small)
        visionQueue.async {
            let focus = runVision(on: input.image)
            result.withLock { $0 = focus }
            done.signal()
        }
        guard done.wait(timeout: .now() + visionTimeout) == .success else {
            visionDisabled.withLock { $0 = true }
            StillroomLog.loading.error(
                "Vision didn't answer within 3 s; face/subject detection is off until the app restarts"
            )
            return nil
        }
        return result.withLock { $0 }
    }

    private static func runVision(on small: CGImage) -> CGPoint? {
        let handler = VNImageRequestHandler(cgImage: small)
        let faces = VNDetectFaceRectanglesRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        try? handler.perform([faces, saliency])

        var region: CGRect?
        if let found = faces.results, !found.isEmpty {
            region = found.map(\.boundingBox).reduce(found[0].boundingBox) { $0.union($1) }
        } else if let objects = saliency.results?.first?.salientObjects, !objects.isEmpty {
            region = objects.map(\.boundingBox).reduce(objects[0].boundingBox) { $0.union($1) }
        }
        // Vision uses a bottom-left origin.
        return region.map { CGPoint(x: $0.midX, y: 1 - $0.midY) }
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// A tiny, heavily blurred copy; scaled up behind the photo it reads as a soft glow.
    private static func makeBackdrop(from image: CGImage) -> CGImage? {
        guard let small = try? downscale(image, maxDimension: 64) else { return nil }
        let input = CIImage(cgImage: small)
        guard let blurred = input.clampedToExtent()
            .applyingGaussianBlur(sigma: 4)
            .cropped(to: input.extent) as CIImage? else { return nil }
        return ciContext.createCGImage(blurred, from: input.extent)
    }

    private static func downscale(_ image: CGImage, maxDimension: CGFloat) throws -> CGImage {
        let scale = min(1, maxDimension / CGFloat(max(image.width, image.height)))
        return try draw(
            UIImage(cgImage: image),
            size: CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        )
    }
}
