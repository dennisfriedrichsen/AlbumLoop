import SwiftUI

/// Grid of the user's ordinary Photos albums, arranged in the same folders as in Photos.
/// With no folder this is the top level of My Albums; a folder opens another grid.
struct AlbumGridView: View {
    var folderID: String?

    @Environment(PhotoLibraryModel.self) private var library
    @Environment(RecentPlaybackStore.self) private var recents
    @AppStorage(SettingsKey.showDiagnostics) private var showDiagnostics = false
    @State private var request: SlideshowRequest?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 48), count: 4)

    private var folder: AlbumFolder? {
        folderID.flatMap { library.folders[$0] }
    }

    private var items: [LibraryItem] {
        folderID == nil ? library.rootItems : folder?.items ?? []
    }

    var body: some View {
        Group {
            if !library.hasLoadedAlbums {
                ProgressView("Loading albums…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if folderID != nil, folder == nil {
                StatusMessageView(
                    systemImage: "folder.badge.questionmark",
                    title: "Folder Not Found",
                    message: "This folder was deleted or no longer contains any albums."
                )
            } else if library.albums.isEmpty {
                StatusMessageView(
                    systemImage: "rectangle.stack.badge.minus",
                    title: "No Albums Found",
                    message: "Stillroom shows albums you created in Photos. Shared Albums aren’t included.\n\n"
                        + "If you just turned on iCloud Photos on this Apple TV, albums can take a while to appear."
                ) {
                    Button("Reload") { Task { await library.loadAlbums() } }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 40) {
                        if folderID == nil, !recentAlbums.isEmpty {
                            recentlyPlayed
                        }
                        header
                        LazyVGrid(columns: columns, spacing: 60) {
                            ForEach(items) { item in
                                switch item {
                                case .album(let id):
                                    if let album = library.album(id: id) {
                                        NavigationLink(value: album) {
                                            AlbumCard(album: album)
                                        }
                                        .buttonStyle(.card)
                                    }
                                case .folder(let id):
                                    if let folder = library.folders[id] {
                                        NavigationLink(value: AppDestination.folder(id: id)) {
                                            FolderCard(folder: folder, albums: library.albums(inFolder: id))
                                        }
                                        .buttonStyle(.card)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 60)
                }
            }
        }
        .task {
            if !library.hasLoadedAlbums {
                await library.loadAlbums()
            }
        }
        .fullScreenCover(item: $request) { request in
            SlideshowLaunch(album: request.album, resume: request.resume)
        }
    }

    /// Recently played albums still in the library, newest first.
    private var recentAlbums: [(album: AlbumSummary, entry: RecentPlayback)] {
        recents.items.compactMap { entry in
            guard let album = library.album(id: entry.albumID), album.photoCount != 0 else { return nil }
            return (album, entry)
        }
    }

    /// Like the TV app's Continue Watching: selecting a card picks the
    /// slideshow up where it was left; hold Select for more options.
    private var recentlyPlayed: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Recently Played")
                .font(.title3.bold())
            ScrollView(.horizontal) {
                LazyHStack(spacing: 48) {
                    ForEach(recentAlbums, id: \.album.id) { item in
                        Button {
                            request = SlideshowRequest(album: item.album, resume: item.entry.resume)
                        } label: {
                            RecentAlbumCard(album: item.album, resume: item.entry.resume)
                        }
                        .buttonStyle(.card)
                        .contextMenu {
                            if item.entry.resume != nil {
                                Button("Start Over", systemImage: "arrow.counterclockwise") {
                                    request = SlideshowRequest(album: item.album, resume: nil)
                                }
                            }
                            Button("Remove from Recently Played", systemImage: "minus.circle", role: .destructive) {
                                recents.remove(albumID: item.album.id)
                            }
                        }
                    }
                }
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 8) {
                Text(folder?.title ?? "Albums")
                    .font(.largeTitle.bold())
                Text(folderID == nil ? summary : folderSummary)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if folderID == nil {
                Button {
                    Task { await library.loadAlbums() }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .disabled(library.isLoadingAlbums)
                NavigationLink(value: AppDestination.about) {
                    Label("About", systemImage: "info.circle")
                }
            }
        }
    }

    private var folderSummary: String {
        guard let folderID else { return "" }
        return folderContentsText(albums: library.albums(inFolder: folderID).count, folders: items.filter {
            if case .folder = $0 { true } else { false }
        }.count)
    }

    private var summary: String {
        let eligible = library.albums.filter { ($0.photoCount ?? 0) > 0 }.count
        var text = "\(library.albums.count) albums"
        if !library.folders.isEmpty {
            text += " in \(library.folders.count) \(library.folders.count == 1 ? "folder" : "folders")"
        }
        if library.isLoadingAlbums && library.countedAlbums < library.albums.count {
            text += " · counting photos (\(library.countedAlbums) of \(library.albums.count) albums)…"
        } else if eligible != library.albums.count {
            text += " · \(eligible) with photos"
        }
        if library.access == .limited {
            text += " · Limited access: only photos you selected are visible"
        }
        if showDiagnostics {
            text += " · eligible albums: \(eligible)"
        }
        return text
    }
}

/// A folder from Photos; its cover is the first album cover found inside it.
struct FolderCard: View {
    let folder: AlbumFolder
    /// Every album in the folder, including subfolders.
    let albums: [AlbumSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AlbumThumbnail(assetID: albums.lazy.compactMap(\.keyAssetID).first)
                .frame(height: 230)
                .clipped()
            VStack(alignment: .leading, spacing: 6) {
                Text(folder.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(folderContentsText(albums: albums.count, folders: nil))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Folder \(folder.title)")
    }
}

func folderContentsText(albums: Int, folders: Int?) -> String {
    var text = albums == 1 ? "1 album" : "\(albums.formatted()) albums"
    if let folders, folders > 0 {
        text += folders == 1 ? " · 1 folder" : " · \(folders) folders"
    }
    return text
}

struct AlbumCard: View {
    let album: AlbumSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AlbumThumbnail(assetID: album.keyAssetID)
                .frame(height: 230)
                .clipped()
            VStack(alignment: .leading, spacing: 6) {
                Text(album.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(photoCountText(album.photoCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Wide card for the Recently Played row, with a progress bar when the
/// slideshow was left part way through.
struct RecentAlbumCard: View {
    let album: AlbumSummary
    let resume: ResumePoint?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AlbumThumbnail(assetID: album.keyAssetID)
                .frame(width: 640, height: 360)
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 14) {
                Text(album.title)
                    .font(.headline)
                    .lineLimit(1)
                if let resume {
                    Text("Photo \((resume.position + 1).formatted()) of \(resume.total.formatted())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ResumeProgressBar(fraction: resume.fraction)
                } else {
                    Text(photoCountText(album.photoCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.white)
            .padding(28)
        }
        .frame(width: 640, height: 360)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let resume else { return album.title }
        return "\(album.title), resume from photo \(resume.position + 1) of \(resume.total)"
    }
}

/// Thin capsule progress bar, as on the TV app's Continue Watching row.
struct ResumeProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(.white)
                    .frame(width: max(8, proxy.size.width * fraction))
            }
        }
        .frame(height: 8)
    }
}

struct AlbumThumbnail: View {
    let assetID: String?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color(white: 0.15))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 60))
                    .foregroundStyle(.tertiary)
            }
        }
        .task(id: assetID) {
            guard let assetID else { return }
            image = await ThumbnailLoader.shared.thumbnail(for: assetID, pixelSize: CGSize(width: 800, height: 460))
        }
    }
}

func photoCountText(_ count: Int?) -> String {
    switch count {
    case nil: "Counting photos…"
    case 0: "No photos"
    case 1: "1 photo"
    case let count?: "\(count.formatted()) photos"
    }
}
