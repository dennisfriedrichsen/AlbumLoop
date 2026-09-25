import StillroomCore
import SwiftUI

/// Album details, slideshow options, and the Play button.
struct AlbumDetailView: View {
    let album: AlbumSummary

    @Environment(PhotoLibraryModel.self) private var library
    @Environment(RecentPlaybackStore.self) private var recents
    @AppStorage(SettingsKey.slideSeconds) private var slideSeconds = SettingsDefault.slideSeconds
    @AppStorage(SettingsKey.shuffle) private var shuffle = false
    @AppStorage(SettingsKey.loop) private var loop = true
    @AppStorage(SettingsKey.showCounter) private var showCounter = true
    @AppStorage(SettingsKey.albumOrder) private var albumOrder = AlbumOrder.album
    @AppStorage(SettingsKey.showDiagnostics) private var showDiagnostics = false
    @AppStorage(SettingsKey.verticalStyle) private var verticalStyle = VerticalPhotoStyle.recommended
    @State private var request: SlideshowRequest?
    @FocusState private var playFocused: Bool

    private var current: AlbumSummary {
        library.album(id: album.id) ?? album
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
                if let resume = recents.entry(for: current.id)?.resume {
                    Button {
                        request = SlideshowRequest(album: current, resume: resume)
                    } label: {
                        Label("Resume from Photo \((resume.position + 1).formatted())", systemImage: "play.fill")
                            .frame(minWidth: 420)
                    }
                    .focused($playFocused)
                    ResumeProgressBar(fraction: resume.fraction)
                        .frame(width: 420)
                    Button {
                        request = SlideshowRequest(album: current, resume: nil)
                    } label: {
                        Label("Start Over", systemImage: "arrow.counterclockwise")
                            .frame(minWidth: 420)
                    }
                } else {
                    Button {
                        request = SlideshowRequest(album: current, resume: nil)
                    } label: {
                        Label("Play Slideshow", systemImage: "play.fill")
                            .frame(minWidth: 420)
                    }
                    .disabled(current.photoCount == 0)
                    .focused($playFocused)
                }
            }
            // Full-height focus section: pressing left from any settings row lands
            // on Play, not just from rows level with the button.
            .frame(width: 720, alignment: .top)
            .frame(maxHeight: .infinity, alignment: .top)
            .focusSection()

            Form {
                Section("Playback") {
                    Toggle("Shuffle", isOn: $shuffle)
                    ChoicePicker("Order", selection: $albumOrder, options: AlbumOrder.allCases) { $0.label }
                    .disabled(shuffle)
                    Toggle("Loop", isOn: $loop)
                    ChoicePicker("Slide Duration", selection: $slideSeconds, options: SettingsDefault.durations) {
                        "\($0) seconds"
                    }
                }
                Section {
                    ChoicePicker(
                        "Vertical Photos",
                        selection: $verticalStyle,
                        options: VerticalPhotoStyle.allCases,
                        label: styleLabel
                    )
                } header: {
                    Text("Vertical Photos")
                } footer: {
                    Text(verticalFooter)
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
        .fullScreenCover(item: $request) { request in
            SlideshowLaunch(album: request.album, resume: request.resume)
        }
    }

    private func styleLabel(_ style: VerticalPhotoStyle) -> String {
        style == .blurredBackground ? "\(style.label) (best for older Apple TVs)" : style.label
    }

    private var verticalFooter: String {
        var text = verticalStyle.explanation
        if DeviceClass.current.isOlderModel, verticalStyle != .blurredBackground {
            text += " This Apple TV is an older model; Blurred Background runs most smoothly on it."
        } else if !DeviceClass.current.isOlderModel, verticalStyle == .blurredBackground {
            text += " Older Apple TVs are the Apple TV HD and Apple TV 4K (1st generation)."
        }
        return text
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
