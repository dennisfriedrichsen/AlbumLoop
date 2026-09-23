import AlbumLoopCore
import SwiftUI

/// Full-screen slideshow presentation and Siri Remote handling.
///
/// Remote: left/right = previous/next, Play/Pause = pause/resume,
/// click or up/down = show controls, Menu/Back = hide controls, then exit.
struct SlideshowView: View {
    let controller: SlideshowController
    let albumTitle: String
    let isNetworkAvailable: Bool
    let onExit: () -> Void
    let onRestart: () -> Void

    @Environment(PhotoLibraryModel.self) private var library
    @AppStorage(SettingsKey.showCounter) private var showCounter = true
    @AppStorage(SettingsKey.showDiagnostics) private var showDiagnostics = false
    @State private var controlsVisible = false
    @State private var hideControlsTask: Task<Void, Never>?
    @FocusState private var focus: Focus?

    private enum Focus: Hashable {
        case canvas
        case controls
        case panel
    }

    private var hasPanel: Bool {
        switch controller.phase {
        case .stalled, .finished, .failed: true
        case .idle, .loading, .showing: false
        }
    }

    private var slideKey: String {
        guard let slide = controller.displayed else { return "none" }
        return "\(slide.cycle)-\(slide.position)"
    }

    var body: some View {
        ZStack {
            canvas
            statusOverlays
                .allowsHitTesting(false)
            if hasPanel {
                panel
                    .transition(.opacity)
            } else if controlsVisible {
                controlsBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: controlsVisible)
        .animation(.easeInOut(duration: 0.3), value: hasPanel)
        .onPlayPauseCommand {
            controller.togglePause()
            if controller.isPaused { revealControls() }
        }
        .onExitCommand {
            if controlsVisible && !hasPanel {
                hideControls()
            } else {
                onExit()
            }
        }
        .onChange(of: hasPanel, initial: true) { _, showing in
            focus = showing ? .panel : (controlsVisible ? .controls : .canvas)
        }
        .onDisappear { hideControlsTask?.cancel() }
    }

    // MARK: Canvas

    private var canvas: some View {
        ZStack {
            Color.black
            if let slide = controller.displayed, let cgImage = slide.image.cgImage {
                Image(cgImage, scale: 1, label: Text("Photo \(slide.position + 1) of \(controller.total)"))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(slideKey)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: slideKey)
        .ignoresSafeArea()
        .focusable(!hasPanel && !controlsVisible)
        .focused($focus, equals: .canvas)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .left: controller.previous()
            case .right: controller.next()
            case .up, .down: revealControls()
            @unknown default: break
            }
        }
        .onTapGesture { revealControls() }
    }

    // MARK: Status overlays (non-interactive)

    private var statusOverlays: some View {
        ZStack {
            if controller.phase == .loading && controller.displayed == nil {
                VStack(spacing: 24) {
                    ProgressView()
                    Text(loadingText(first: true))
                        .foregroundStyle(.secondary)
                }
            }

            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 16) {
                        if controller.isPaused {
                            Label("Paused", systemImage: "pause.fill")
                                .pill()
                        }
                        if showDiagnostics {
                            DiagnosticsOverlay(
                                diagnostics: controller.diagnostics,
                                eligibleAlbums: library.albums.filter { $0.photoCount > 0 }.count,
                                phase: controller.phase,
                                isNetworkAvailable: isNetworkAvailable
                            )
                        }
                    }
                    Spacer()
                    if controller.phase == .loading && controller.displayed != nil {
                        HStack(spacing: 14) {
                            ProgressView()
                                .scaleEffect(0.6)
                            Text(loadingText(first: false))
                        }
                        .pill()
                        .transition(.opacity)
                    }
                }
                Spacer()
                HStack(alignment: .bottom) {
                    if let notice = controller.notice {
                        Text(notice)
                            .pill()
                            .transition(.opacity)
                    }
                    Spacer()
                    if showCounter && controller.total > 0 && !hasPanel {
                        Text(counterText)
                            .monospacedDigit()
                            .pill()
                    }
                }
            }
            .padding(10)
        }
        .animation(.easeInOut(duration: 0.3), value: controller.phase)
        .animation(.easeInOut(duration: 0.3), value: controller.notice)
    }

    private var counterText: String {
        let position = controller.targetPosition + 1
        return "Photo \(position.formatted()) of \(controller.total.formatted())"
    }

    private func loadingText(first: Bool) -> String {
        if !isNetworkAvailable {
            return "Waiting for network…"
        }
        if controller.isRetryingTarget {
            return "Having trouble loading — retrying…"
        }
        if let progress = controller.targetProgress {
            return "Downloading from iCloud \(Int(progress * 100))%"
        }
        return first ? "Loading first photo…" : "Loading next photo…"
    }

    // MARK: Panels

    @ViewBuilder
    private var panel: some View {
        switch controller.phase {
        case .stalled(let failure):
            PanelView(
                title: controller.displayed == nil
                    ? "Couldn’t Load the First Photo"
                    : "Couldn’t Load Photo \(controller.targetPosition + 1) of \(controller.total)",
                message: stalledMessage(failure)
            ) {
                Button("Retry") { controller.retryCurrent() }
                    .focused($focus, equals: .panel)
                Button("Skip Photo") { controller.skipCurrent() }
                Button("Exit", action: onExit)
            }
        case .finished:
            PanelView(
                title: "Slideshow Finished",
                message: controller.lastCycleReport?.summary ?? ""
            ) {
                Button("Play Again", action: onRestart)
                    .focused($focus, equals: .panel)
                Button("Done", action: onExit)
            }
        case .failed(let message):
            PanelView(title: "Can’t Continue", message: message) {
                Button("Try Again", action: onRestart)
                    .focused($focus, equals: .panel)
                Button("Done", action: onExit)
            }
        case .idle, .loading, .showing:
            EmptyView()
        }
    }

    private func stalledMessage(_ failure: ImageLoadFailure) -> String {
        var lines = [failure.message]
        if !isNetworkAvailable {
            lines.append("This Apple TV appears to be offline. AlbumLoop will try again automatically when the network returns.")
        }
        lines.append("The slideshow is holding here. Nothing is skipped unless you choose Skip Photo, and skipped photos are listed at the end of the cycle.")
        return lines.joined(separator: "\n\n")
    }

    // MARK: Controls

    private var controlsBar: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text(albumTitle)
                        .font(.title3.bold())
                    Spacer()
                    Text(counterText)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 30) {
                    Button { controller.previous(); scheduleHide() } label: {
                        Label("Previous", systemImage: "backward.fill")
                    }
                    Button { controller.togglePause(); scheduleHide() } label: {
                        Label(controller.isPaused ? "Play" : "Pause",
                              systemImage: controller.isPaused ? "play.fill" : "pause.fill")
                    }
                    .focused($focus, equals: .controls)
                    Button { controller.next(); scheduleHide() } label: {
                        Label("Next", systemImage: "forward.fill")
                    }
                    Button { controller.setLoops(!controller.settings.loops); scheduleHide() } label: {
                        Label(controller.settings.loops ? "Loop On" : "Loop Off", systemImage: "repeat")
                    }
                    Button { showCounter.toggle(); scheduleHide() } label: {
                        Label(showCounter ? "Counter On" : "Counter Off", systemImage: "number")
                    }
                    Spacer()
                    Button("Exit", action: onExit)
                }
                Text("◀︎ ▶︎ previous / next   ·   ⏯ pause / play   ·   Back hides controls")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(50)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30))
        }
        .padding(.bottom, 20)
    }

    private func revealControls() {
        guard !hasPanel else { return }
        controlsVisible = true
        focus = .controls
        scheduleHide()
    }

    private func hideControls() {
        hideControlsTask?.cancel()
        controlsVisible = false
        focus = .canvas
    }

    private func scheduleHide() {
        hideControlsTask?.cancel()
        hideControlsTask = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            // Stay visible while paused so the state is obvious.
            if !controller.isPaused {
                hideControls()
            }
        }
    }
}

/// Centered card with a title, explanation, and buttons.
private struct PanelView<Actions: View>: View {
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 30) {
            Text(title)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack(spacing: 30) {
                actions
            }
            .focusSection()
        }
        .padding(60)
        .frame(maxWidth: 1200)
        .background(Color(white: 0.08).opacity(0.92), in: RoundedRectangle(cornerRadius: 30))
    }
}

private extension View {
    /// Small translucent capsule used for status text over photos.
    func pill() -> some View {
        font(.callout)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.white)
    }
}
