import AlbumLoopCore
import SwiftUI

/// Album details, slideshow options, and the Play button.
struct AlbumDetailView: View {
    let album: AlbumSummary

    @Environment(PhotoLibraryModel.self) private var library
    @AppStorage(SettingsKey.slideSeconds) private var slideSeconds = SettingsDefault.slideSeconds
    @AppStorage(SettingsKey.shuffle) private var shuffle = false
    @AppStorage(SettingsKey.loop) private var loop = true
    @AppStorage(SettingsKey.showCounter) private var showCounter = true
    @AppStorage(SettingsKey.albumOrder) private var albumOrder = AlbumOrder.album
    @AppStorage(SettingsKey.showDiagnostics) private var showDiagnostics = false
    @State private var isPlaying = false
    @FocusState private var playFocused: Bool

    private var current: AlbumSummary {
        library.albums.first { $0.id == album.id } ?? album
    }

    var body: some View {
        HStack(alignment: .top, spacing: 80) {
            VStack(alignment: .leading, spacing: 30) {
                AlbumThumbnail(assetID: current.keyAssetID)
                    .frame(width: 720, height: 405)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                Text(current.title)
                    .font(.title2.bold())
                Text("\(photoCountText(current.photoCount)) · videos are not included")
                    .foregroundStyle(.secondary)
                Button {
                    isPlaying = true
                } label: {
                    Label("Play Slideshow", systemImage: "play.fill")
                        .frame(minWidth: 420)
                }
                .disabled(current.photoCount == 0)
                .focused($playFocused)
            }
            .frame(width: 720)

            Form {
                Section("Playback") {
                    Toggle("Shuffle", isOn: $shuffle)
                    Picker("Order", selection: $albumOrder) {
                        ForEach(AlbumOrder.allCases) { order in
                            Text(order.label).tag(order)
                        }
                    }
                    .disabled(shuffle)
                    Toggle("Loop", isOn: $loop)
                    Picker("Slide Duration", selection: $slideSeconds) {
                        ForEach(SettingsDefault.durations, id: \.self) { seconds in
                            Text("\(seconds) seconds").tag(seconds)
                        }
                    }
                }
                Section("Display") {
                    Toggle("Show “Photo 12 of 600”", isOn: $showCounter)
                    Toggle("Diagnostics Overlay", isOn: $showDiagnostics)
                }
                Section("Troubleshooting") {
                    NavigationLink("Test iCloud Loading") {
                        CloudProbeView(album: current)
                    }
                }
            }
        }
        .padding(60)
        .defaultFocus($playFocused, true)
        .fullScreenCover(isPresented: $isPlaying) {
            SlideshowScreen(
                album: current,
                order: albumOrder,
                settings: SlideshowSettings(
                    slideDuration: .seconds(slideSeconds),
                    order: shuffle ? .shuffled : .sequential,
                    loops: loop
                )
            )
        }
    }
}

/// Runs the on-device iCloud loading check for one album.
struct CloudProbeView: View {
    let album: AlbumSummary
    @Environment(PhotoLibraryModel.self) private var library
    @State private var probe = CloudProbe()

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            Text("Test iCloud Loading")
                .font(.title2.bold())
            Text(
                "Samples 12 photos spread across “\(album.title)”, checks whether each is already on this Apple TV "
                    + "at screen size, and downloads the ones that aren’t. Nothing is saved."
            )
            .foregroundStyle(.secondary)
            Text(probe.summary)
                .font(.headline)
            List(probe.rows) { row in
                HStack {
                    Text("Photo \(row.position)")
                        .frame(width: 260, alignment: .leading)
                    Text(row.local)
                        .frame(width: 300, alignment: .leading)
                        .foregroundStyle(.secondary)
                    Text(row.download)
                }
            }
        }
        .padding(60)
        .task {
            let ids = await library.assetIDs(forAlbum: album.id, order: .album) ?? []
            await probe.run(ids: ids, sampleCount: 12, targetPixelSize: DisplayMetrics.targetPixelSize())
        }
    }
}
