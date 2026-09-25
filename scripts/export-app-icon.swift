import AppKit
import Foundation

// Run from the repository root: swift scripts/export-app-icon.swift
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = root.appendingPathComponent("design/app-icon-options/stillroom-b-vibrant.png")
guard let source = NSImage(contentsOf: sourceURL) else {
    fatalError("Cannot load approved icon: \(sourceURL.path)")
}
let assets = root.appendingPathComponent("Stillroom/Assets.xcassets/App Icon & Top Shelf Image.brandassets")
let exports = [("App Icon.imagestack", 400, 240),
               ("App Icon.imagestack", 800, 480),
               ("App Icon - App Store.imagestack", 1280, 768)]
for (stack, width, height) in exports {
    for layer in ["Back", "Front"] {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width,
            pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            fatalError("Cannot create icon bitmap")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        if layer == "Back" {
            context.imageInterpolation = .high
            source.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Cannot encode icon PNG")
        }
        let path = "\(stack)/\(layer).imagestacklayer/Content.imageset/\(layer.lowercased())-\(width)x\(height).png"
        try png.write(to: assets.appendingPathComponent(path))
        print("Exported \(path)")
    }
}
