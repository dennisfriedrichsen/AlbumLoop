import Foundation

/// What the app hands the Top Shelf extension: the Recently Played albums with
/// their cover images, shared through the App Group. The extension can't read
/// Photos itself, so the app saves each cover as a small JPEG in the group container.
enum TopShelfFeed {
    static let appGroup = "group.com.friedrichsenweb.Stillroom"
    static let urlScheme = "stillroom"

    struct Item: Codable, Hashable, Sendable {
        var albumID: String
        var title: String
        /// Fraction of the album already shown, or nil when it starts from the beginning.
        var progress: Double?
        /// File name of the cover JPEG in `imagesDirectory`.
        var imageFileName: String?
    }

    /// Covers go in the group's Library/Caches: tvOS apps can't write elsewhere
    /// in a container. The system may purge it, so the app re-saves missing
    /// covers each time it publishes.
    static var imagesDirectory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("Library/Caches/TopShelf", isDirectory: true)
    }

    private static let feedKey = "topShelfFeed"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func read() -> [Item] {
        guard let data = defaults?.data(forKey: feedKey) else { return [] }
        return (try? JSONDecoder().decode([Item].self, from: data)) ?? []
    }

    static func write(_ items: [Item]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults?.set(data, forKey: feedKey)
    }

    /// `stillroom://play?album=<id>`: opens the app and plays or resumes the album.
    static func playURL(albumID: String) -> URL? {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = "play"
        components.queryItems = [URLQueryItem(name: "album", value: albumID)]
        return components.url
    }

    /// The album identifier from a `playURL`, or nil for any other URL.
    static func albumID(from url: URL) -> String? {
        guard url.scheme == urlScheme, url.host == "play" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "album" }?.value
    }
}
