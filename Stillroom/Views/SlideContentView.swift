import StillroomCore
import SwiftUI

/// Draws one slide (one photo, or a side-by-side pair) in the chosen style.
struct SlideContentView: View {
    let slide: DisplayedSlide
    let total: Int
    let style: VerticalPhotoStyle
    let controller: SlideshowController
    /// False for the outgoing slide during a crossfade; it holds its final pan position.
    var isCurrent = true

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if style.usesBackdrop, let backdrop = slide.photos[0].image.backdrop {
                    Image(decorative: backdrop, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .overlay(Color.black.opacity(0.35))
                }
                if slide.photos.count > 1 {
                    pair(in: geometry.size)
                } else if let photo = slide.photos.first {
                    if style == .slowPan, let cgImage = photo.image.cgImage,
                       pans(cgImage, in: geometry.size) {
                        PanningImage(
                            image: cgImage,
                            focus: photo.image.focus,
                            viewSize: geometry.size,
                            label: label(for: slide.position + 1),
                            controller: controller,
                            isCurrent: isCurrent
                        )
                    } else {
                        fitted(photo, label: slide.position + 1)
                    }
                }
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func fitted(_ photo: DisplayedPhoto, label position: Int) -> some View {
        if let cgImage = photo.image.cgImage {
            Image(cgImage, scale: 1, label: Text(label(for: position)))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Two photos at the same height, as large as fits, with a small gap between them.
    private func pair(in size: CGSize) -> some View {
        let gap: CGFloat = 24
        let aspects = slide.photos.map { photo -> CGFloat in
            guard let image = photo.image.cgImage, image.height > 0 else { return 0.75 }
            return CGFloat(image.width) / CGFloat(image.height)
        }
        let height = min(size.height, (size.width - gap * 3) / max(0.1, aspects.reduce(0, +)))
        return HStack(spacing: gap) {
            ForEach(Array(slide.photos.enumerated()), id: \.offset) { index, photo in
                if let cgImage = photo.image.cgImage {
                    Image(cgImage, scale: 1, label: Text(label(for: slide.position + index + 1)))
                        .resizable()
                        .frame(width: height * aspects[index], height: height)
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// Pan only images rendered for panning, i.e. taller than the screen at full width.
    private func pans(_ image: CGImage, in size: CGSize) -> Bool {
        guard image.width > 0, size.width > 0 else { return false }
        let heightAtFullWidth = size.width * CGFloat(image.height) / CGFloat(image.width)
        return heightAtFullWidth > size.height * 1.05
    }

    private func label(for position: Int) -> String {
        "Photo \(position) of \(total)"
    }
}

/// A photo scaled to the screen's width that moves vertically over the slide's
/// display time, ending on the detected face or subject.
private struct PanningImage: View {
    let image: CGImage
    let focus: CGPoint?
    let viewSize: CGSize
    let label: String
    let controller: SlideshowController
    let isCurrent: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let height = viewSize.width * CGFloat(image.height) / CGFloat(image.width)
        let path = Self.path(imageHeight: height, viewHeight: viewSize.height, focus: focus)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !isCurrent)) { _ in
            let top = reduceMotion || !isCurrent ? path.end : path.offset(at: progress)
            Image(image, scale: 1, label: Text(label))
                .resizable()
                .frame(width: viewSize.width, height: height)
                .offset(y: -top)
                .frame(width: viewSize.width, height: viewSize.height, alignment: .top)
                .clipped()
        }
    }

    private var progress: Double {
        let duration = controller.settings.slideDuration
        guard duration > .zero else { return 1 }
        return min(1, max(0, controller.slideElapsed / duration))
    }

    struct Path {
        let start: CGFloat
        let end: CGFloat

        /// Smooth ease-in-out between the two offsets.
        func offset(at progress: Double) -> CGFloat {
            let t = CGFloat(progress)
            let eased = t * t * (3 - 2 * t)
            return start + (end - start) * eased
        }
    }

    /// Starts at the edge farther from the subject and ends with the subject
    /// centred (clamped). Without a detected subject, assumes it's in the upper
    /// third, where faces usually are, so the pan doesn't end on someone's feet.
    static func path(imageHeight: CGFloat, viewHeight: CGFloat, focus: CGPoint?) -> Path {
        let travel = max(0, imageHeight - viewHeight)
        guard travel > 0 else { return Path(start: 0, end: 0) }
        let focusY = focus?.y ?? 0.33
        let target = min(max(0, focusY * imageHeight - viewHeight / 2), travel)
        let start: CGFloat = target > travel / 2 ? 0 : travel
        // Always move a meaningful distance.
        let end = abs(target - start) < travel * 0.3 ? travel - start : target
        return Path(start: start, end: end)
    }
}
