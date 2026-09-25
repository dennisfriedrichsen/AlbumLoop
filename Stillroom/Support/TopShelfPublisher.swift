import StillroomCore
import TVServices
import UIKit

/// Keeps the Top Shelf feed in the App Group container in step with Recently
/// Played, saving each album's cover as a JPEG the extension can show.
@MainActor
enum TopShelfPublisher {
    /// Top Shelf sectioned items in the 16:9 shape, at 2x.
    private static let coverSize = CGSize(width: 816, height: 459)

    static func publish(recents: [RecentPlayback], library: PhotoLibraryModel) async {
        guard library.hasLoadedAlbums else { return }
        guard let directory = TopShelfFeed.imagesDirectory else {
            StillroomLog.library.error("Top Shelf: App Group container unavailable")
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            StillroomLog.library.error("Top Shelf: can't create cover folder: \(error.localizedDescription)")
        }

        var items: [TopShelfFeed.Item] = []
        var covers: Set<String> = []
        for entry in recents {
            guard let album = library.album(id: entry.albumID), album.photoCount != 0 else { continue }
            var imageFileName: String?
            if let assetID = album.keyAssetID {
                let name = fileName(for: assetID)
                let url = directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) {
                    imageFileName = name
                } else if await saveCover(assetID: assetID, to: url) {
                    imageFileName = name
                }
                if imageFileName != nil { covers.insert(name) }
            }
            items.append(TopShelfFeed.Item(
                albumID: album.id,
                title: album.title,
                progress: entry.resume.map { ($0.fraction * 100).rounded() / 100 },
                imageFileName: imageFileName
            ))
        }
        if Task.isCancelled { return }

        // Drop covers of albums that left the row.
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in existing where !covers.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }

        guard items != TopShelfFeed.read() else { return }
        TopShelfFeed.write(items)
        TVTopShelfContentProvider.topShelfContentDidChange()
        StillroomLog.library.info("Top Shelf: published \(items.count) albums, \(covers.count) covers")
    }

    /// PhotoKit identifiers contain slashes, so encode them into a file name.
    private static func fileName(for assetID: String) -> String {
        (assetID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? UUID().uuidString) + ".jpg"
    }

    private static func saveCover(assetID: String, to url: URL) async -> Bool {
        guard let image = await ThumbnailLoader.shared.thumbnail(for: assetID, pixelSize: coverSize) else {
            StillroomLog.library.error("Top Shelf: no cover image for an album")
            return false
        }
        // Crop to exactly 16:9 so the shelf doesn't letterbox the cover.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let cropped = UIGraphicsImageRenderer(size: coverSize, format: format).image { _ in
            let scale = max(coverSize.width / image.size.width, coverSize.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(
                x: (coverSize.width - size.width) / 2,
                y: (coverSize.height - size.height) / 2,
                width: size.width,
                height: size.height
            ))
        }
        guard let data = cropped.jpegData(compressionQuality: 0.85) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            StillroomLog.library.error("Top Shelf: can't save cover: \(error.localizedDescription)")
            return false
        }
    }
}
