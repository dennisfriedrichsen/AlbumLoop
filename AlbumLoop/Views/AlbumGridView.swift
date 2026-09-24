import SwiftUI

/// Grid of the user's ordinary Photos albums.
struct AlbumGridView: View {
    @Environment(PhotoLibraryModel.self) private var library
    @AppStorage(SettingsKey.showDiagnostics) private var showDiagnostics = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 48), count: 4)

    var body: some View {
        Group {
            if !library.hasLoadedAlbums {
                ProgressView("Loading albums…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if library.albums.isEmpty {
                StatusMessageView(
                    systemImage: "rectangle.stack.badge.minus",
                    title: "No Albums Found",
                    message: "AlbumLoop shows albums you created in Photos. Shared Albums aren’t included.\n\n"
                        + "If you just turned on iCloud Photos on this Apple TV, albums can take a while to appear."
                ) {
                    Button("Reload") { Task { await library.loadAlbums() } }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 40) {
                        header
                        LazyVGrid(columns: columns, spacing: 60) {
                            ForEach(library.albums) { album in
                                NavigationLink(value: album) {
                                    AlbumCard(album: album)
                                }
                                .buttonStyle(.card)
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
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Albums")
                    .font(.largeTitle.bold())
                Text(summary)
                    .foregroundStyle(.secondary)
            }
            Spacer()
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

    private var summary: String {
        let eligible = library.albums.filter { ($0.photoCount ?? 0) > 0 }.count
        var text = "\(library.albums.count) albums"
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
