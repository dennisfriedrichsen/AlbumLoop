import AppKit
import Foundation

// Run from the repository root: swift scripts/export-top-shelf.swift
//
// Draws the static Top Shelf images (shown when there are no recently played
// albums) from the approved icon's mark. The Home screen crops the wide image
// to the middle 1920 points and the app row covers its lower edge, so the mark
// and name sit centered and slightly high.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = root.appendingPathComponent("design/app-icon-options/stillroom-b-vibrant.png")
guard let source = NSImage(contentsOf: sourceURL),
      let sourceBitmap = source.representations.first as? NSBitmapImageRep else {
    fatalError("Cannot load approved icon: \(sourceURL.path)")
}
// The interlocked frames, in the source's pixels (top-left origin), with a margin.
let markPixels = NSRect(x: 440, y: 170, width: 740, height: 590)
// The icon's background colour; the mark is composited with .lighten so the
// source background disappears into this one.
let background = NSColor(srgbRed: 14 / 255, green: 18 / 255, blue: 34 / 255, alpha: 1)
let purple = NSColor(srgbRed: 139 / 255, green: 92 / 255, blue: 246 / 255, alpha: 1)
let cyan = NSColor(srgbRed: 34 / 255, green: 211 / 255, blue: 238 / 255, alpha: 1)

let assets = root.appendingPathComponent("Stillroom/Assets.xcassets/App Icon & Top Shelf Image.brandassets")
let exports = [("Top Shelf Image Wide.imageset", 2320),
               ("Top Shelf Image.imageset", 1920)]

for (imageSet, pointWidth) in exports {
    for scale in [1, 2] {
        let width = pointWidth * scale, height = 720 * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width,
            pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            fatalError("Cannot create Top Shelf bitmap")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        // Draw in points; AppKit's origin is bottom-left.
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(scale))
        transform.concat()
        let size = NSSize(width: pointWidth, height: 720)

        background.setFill()
        NSRect(origin: .zero, size: size).fill()

        // Layout: mark, gap, then the name with a tagline beneath it.
        let markHeight: CGFloat = 330
        let markWidth = markHeight * markPixels.width / markPixels.height
        let gap: CGFloat = 50
        let titleFont = NSFont.systemFont(ofSize: 124, weight: .bold).rounded
        let taglineFont = NSFont.systemFont(ofSize: 40, weight: .medium).rounded
        let title = NSAttributedString(string: "Stillroom", attributes: [
            .font: titleFont, .foregroundColor: NSColor.white,
        ])
        let tagline = NSAttributedString(string: "Slideshows of your whole album", attributes: [
            .font: taglineFont, .foregroundColor: NSColor.white.withAlphaComponent(0.62),
        ])
        let textWidth = max(title.size().width, tagline.size().width)
        let groupWidth = markWidth + gap + textWidth
        let centerY: CGFloat = 720 - 330
        let markRect = NSRect(x: (size.width - groupWidth) / 2, y: centerY - markHeight / 2,
                              width: markWidth, height: markHeight)

        // Soft glows in the icon's two colours behind the mark.
        for (color, dx, radius, alpha) in [(purple, -0.18, 520.0, 0.30), (cyan, 0.22, 560.0, 0.22)] {
            let center = NSPoint(x: markRect.midX + markWidth * dx, y: markRect.midY)
            let glow = NSGradient(colors: [color.withAlphaComponent(alpha), color.withAlphaComponent(0)])!
            glow.draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
        }

        let sourceRect = NSRect(x: markPixels.minX, y: CGFloat(sourceBitmap.pixelsHigh) - markPixels.maxY,
                                width: markPixels.width, height: markPixels.height)
        // NSImage uses points; convert from the bitmap's pixels.
        let pointScale = source.size.width / CGFloat(sourceBitmap.pixelsWide)
        source.draw(in: markRect, from: sourceRect.applying(.init(scaleX: pointScale, y: pointScale)),
                    operation: .lighten, fraction: 1)

        let textX = markRect.maxX + gap
        let titleSize = title.size(), taglineSize = tagline.size()
        let spacing: CGFloat = 6
        let textTop = centerY + (titleSize.height + spacing + taglineSize.height) / 2
        title.draw(at: NSPoint(x: textX, y: textTop - titleSize.height))
        tagline.draw(at: NSPoint(x: textX + 4, y: textTop - titleSize.height - spacing - taglineSize.height))

        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Cannot encode Top Shelf PNG")
        }
        let path = "\(imageSet)/shelf-\(scale)x.png"
        try png.write(to: assets.appendingPathComponent(path))
        print("Exported \(path) (\(width)×\(height))")
    }
}

extension NSFont {
    var rounded: NSFont {
        fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: pointSize) } ?? self
    }
}
