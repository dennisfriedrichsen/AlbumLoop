import TVServices

/// Fills the Apple TV Home screen's top shelf, shown when Stillroom is in the
/// top row, with the Recently Played albums the app last saved.
final class ContentProvider: TVTopShelfContentProvider {
    // The completion-handler form: the async override can't return the
    // non-Sendable content under Swift 6 strict concurrency.
    override func loadTopShelfContent(completionHandler: @escaping ((any TVTopShelfContent)?) -> Void) {
        completionHandler(makeContent())
    }

    private func makeContent() -> (any TVTopShelfContent)? {
        let feed = TopShelfFeed.read()
        // Nil falls back to the static Top Shelf image from the asset catalog.
        guard !feed.isEmpty else { return nil }

        let items = feed.map { entry in
            let item = TVTopShelfSectionedItem(identifier: entry.albumID)
            item.title = entry.title
            item.imageShape = .hdtv
            if let name = entry.imageFileName, let url = TopShelfFeed.imagesDirectory?.appendingPathComponent(name) {
                item.setImageURL(url, for: [.screenScale1x, .screenScale2x])
            }
            if let progress = entry.progress {
                item.playbackProgress = progress
            }
            if let url = TopShelfFeed.playURL(albumID: entry.albumID) {
                // Selecting or pressing Play both pick the slideshow up where it stopped,
                // like the Recently Played row in the app.
                item.displayAction = TVTopShelfAction(url: url)
                item.playAction = TVTopShelfAction(url: url)
            }
            return item
        }
        let section = TVTopShelfItemCollection(items: items)
        section.title = "Recently Played"
        return TVTopShelfSectionedContent(sections: [section])
    }
}
