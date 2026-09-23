import Foundation
import Observation

/// User-chosen slideshow options.
public struct SlideshowSettings: Sendable, Equatable {
    public var slideDuration: Duration
    public var order: PlaybackSequence.Order
    public var loops: Bool

    public init(slideDuration: Duration = .seconds(8), order: PlaybackSequence.Order = .sequential, loops: Bool = true) {
        self.slideDuration = slideDuration
        self.order = order
        self.loops = loops
    }
}

/// The slide currently on screen.
public struct DisplayedSlide: Sendable {
    public let id: AssetID
    public let image: LoadedImage
    public let cycle: Int
    /// 0-based position in the cycle.
    public let position: Int
}

/// Drives one slideshow: owns the playback sequence, the image buffer, and the
/// slide timer, and exposes a single explicit phase to the UI.
///
/// All state changes happen on the main actor, and every asynchronous input
/// (timer, image completion, navigation) goes through the same serial event
/// handlers, so timers, downloads, and remote presses cannot race.
@MainActor
@Observable
public final class SlideshowController {
    public enum Phase: Equatable, Sendable {
        /// No slideshow is running.
        case idle
        /// Waiting for the target slide's image. Any previous image stays on screen.
        case loading
        /// The target slide is on screen.
        case showing
        /// The target slide failed after automatic retries; the user can retry or skip.
        case stalled(ImageLoadFailure)
        /// Looping is off and every slide has been visited.
        case finished
        /// Playback cannot continue (for example, nothing in the album could be loaded).
        case failed(String)
    }

    // MARK: Observable state

    public private(set) var phase: Phase = .idle
    public private(set) var isPaused = false
    public private(set) var displayed: DisplayedSlide?
    /// 0-based position of the slide playback is on (which may still be loading).
    public private(set) var targetPosition = 0
    public private(set) var total = 0
    public private(set) var cycle = 1
    /// Download progress for the target slide while loading, if known.
    public private(set) var targetProgress: Double?
    /// True while the target slide is between automatic retries.
    public private(set) var isRetryingTarget = false
    public private(set) var lastCycleReport: CycleReport?
    /// Short-lived message for the user (cycle summary, album change, network).
    public private(set) var notice: String?
    public private(set) var isNetworkAvailable = true
    public private(set) var diagnostics = PlaybackDiagnostics()
    public private(set) var settings: SlideshowSettings

    /// Whether the screen should be kept awake right now.
    public var wantsDisplayAwake: Bool {
        guard !isPaused else { return false }
        switch phase {
        case .loading, .showing: return true
        case .idle, .stalled, .finished, .failed: return false
        }
    }

    // MARK: Private state

    private let provider: any ImageProviding
    private let scheduler: any Scheduling
    private let bufferConfiguration: ImageBuffer.Configuration
    private let targetPixelSize: PixelSize
    private let seedSource: () -> UInt64

    private var buffer: ImageBuffer?
    private var sequence: PlaybackSequence?
    private var sessionID = 0
    private var slideTimer: ScheduledWork?
    private var timerStartedAt: Duration?
    /// Time left on the slide timer when paused.
    private var remainingSlideTime: Duration?
    private var noticeTimer: ScheduledWork?
    private var pendingSnapshot: [AssetID]?
    private var wasPlayingBeforeBackground = false

    private var displayedThisCycle: Set<AssetID> = []
    private var skippedThisCycle: [AssetID] = []
    private var removedThisCycle: [AssetID] = []

    public init(
        provider: any ImageProviding,
        scheduler: any Scheduling,
        targetPixelSize: PixelSize,
        bufferConfiguration: ImageBuffer.Configuration = ImageBuffer.Configuration(),
        settings: SlideshowSettings = SlideshowSettings(),
        seedSource: @escaping () -> UInt64 = { UInt64.random(in: .min ... .max) }
    ) {
        self.provider = provider
        self.scheduler = scheduler
        self.targetPixelSize = targetPixelSize
        self.bufferConfiguration = bufferConfiguration
        self.settings = settings
        self.seedSource = seedSource
    }

    // MARK: Session lifecycle

    /// Starts a new slideshow from a snapshot of eligible asset identifiers.
    /// Any previous session is cancelled and its late callbacks are ignored.
    public func start(assetIDs: [AssetID], settings: SlideshowSettings? = nil) {
        stop()
        if let settings { self.settings = settings }
        sessionID += 1
        guard !assetIDs.isEmpty else {
            phase = .failed("This album has no photos to show.")
            return
        }

        let buffer = ImageBuffer(
            provider: provider,
            scheduler: scheduler,
            targetPixelSize: targetPixelSize,
            configuration: bufferConfiguration
        )
        let session = sessionID
        buffer.onEvent = { [weak self] event in
            self?.handle(event, session: session)
        }
        self.buffer = buffer
        sequence = PlaybackSequence(
            items: assetIDs,
            order: self.settings.order,
            loops: self.settings.loops,
            seed: seedSource()
        )
        total = assetIDs.count
        phase = .loading
        AlbumLoopLog.playback.info(
            "Session \(session) started: \(assetIDs.count) photos, order \(self.settings.order.rawValue, privacy: .public)"
        )
        targetChanged(byNavigation: false)
    }

    /// Ends the slideshow, cancelling timers and every outstanding request.
    public func stop() {
        slideTimer?.cancel()
        slideTimer = nil
        noticeTimer?.cancel()
        noticeTimer = nil
        buffer?.onEvent = nil
        buffer?.reset()
        buffer = nil
        sequence = nil
        displayed = nil
        phase = .idle
        isPaused = false
        targetPosition = 0
        total = 0
        cycle = 1
        targetProgress = nil
        isRetryingTarget = false
        remainingSlideTime = nil
        timerStartedAt = nil
        pendingSnapshot = nil
        notice = nil
        lastCycleReport = nil
        resetCycleTracking()
        publishDiagnostics()
    }

    // MARK: Transport controls

    public func togglePause() {
        isPaused ? resume() : pause()
    }

    /// Stops automatic advancement. Prefetching continues.
    public func pause() {
        guard sequence != nil, !isPaused else { return }
        isPaused = true
        if let slideTimer, let timerStartedAt {
            let elapsed = scheduler.now - timerStartedAt
            remainingSlideTime = max(.zero, settings.slideDuration - elapsed)
            slideTimer.cancel()
        }
        slideTimer = nil
        timerStartedAt = nil
    }

    public func resume() {
        guard sequence != nil, isPaused else { return }
        isPaused = false
        startSlideTimerIfNeeded()
    }

    /// Moves to the next slide in the playback sequence. While stalled on an
    /// unavailable photo this is an explicit skip and is recorded as such.
    public func next() {
        guard sequence != nil else { return }
        switch phase {
        case .stalled:
            skipCurrent()
        case .loading, .showing:
            advance(byUser: true)
        case .idle, .finished, .failed:
            break
        }
    }

    /// Moves back one slide within the current cycle.
    public func previous() {
        guard var sequence else { return }
        switch phase {
        case .loading, .showing, .stalled, .finished:
            guard sequence.retreat() else {
                showNotice("Start of this cycle")
                return
            }
            self.sequence = sequence
            cancelSlideTimer()
            phase = .loading
            targetChanged(byNavigation: true)
        case .idle, .failed:
            break
        }
    }

    /// Tries the stalled slide again with a fresh set of attempts.
    public func retryCurrent() {
        guard let sequence, let buffer else { return }
        if case .stalled = phase {
            phase = .loading
        }
        buffer.retry(sequence.currentID)
        targetChanged(byNavigation: false)
    }

    /// Explicitly skips the slide that could not be loaded and records it.
    public func skipCurrent() {
        guard let sequence, case .stalled = phase else { return }
        let id = sequence.currentID
        if !skippedThisCycle.contains(id) {
            skippedThisCycle.append(id)
        }
        AlbumLoopLog.playback.notice("User skipped unavailable photo \(id.logToken, privacy: .public)")
        advance(byUser: true)
    }

    /// Changes the loop setting for the rest of this session.
    public func setLoops(_ loops: Bool) {
        settings.loops = loops
        sequence?.loops = loops
        refreshWindow()
    }

    /// Restarts playback from the first slide of a new cycle after the
    /// slideshow finished (loop off).
    public func playAgain() {
        guard let sequence, phase == .finished else { return }
        start(assetIDs: pendingSnapshot ?? sequence.items)
    }

    // MARK: Environment events

    public func networkAvailabilityChanged(_ available: Bool) {
        guard available != isNetworkAvailable else { return }
        isNetworkAvailable = available
        guard sequence != nil, let buffer else { return }
        if available {
            AlbumLoopLog.playback.info("Network restored; retrying failed images")
            showNotice("Network restored")
            buffer.retryAllFailed()
            if case .stalled = phase {
                phase = .loading
                targetChanged(byNavigation: false)
            }
        } else {
            showNotice("Network unavailable — photos not already loaded will wait")
        }
    }

    public func handleMemoryPressure() {
        buffer?.handleMemoryPressure()
        publishDiagnostics()
    }

    /// Call when the app leaves the foreground: pauses and cancels prefetching.
    public func enterBackground() {
        guard sequence != nil else { return }
        wasPlayingBeforeBackground = !isPaused
        pause()
        let protectedIDs = [sequence?.currentID, displayed?.id].compactMap { $0 }
        buffer?.setWindow(needed: protectedIDs.first, ahead: [], behind: [], onScreen: displayed?.id)
        publishDiagnostics()
    }

    public func enterForeground() {
        guard sequence != nil else { return }
        refreshWindow()
        if wasPlayingBeforeBackground {
            resume()
        }
        wasPlayingBeforeBackground = false
    }

    /// Supplies a fresh snapshot after the album changed in the library.
    /// The running cycle is never rebuilt; the new snapshot applies from the next cycle.
    public func albumContentsChanged(_ newIDs: [AssetID]) {
        guard let sequence, newIDs != sequence.items else { return }
        pendingSnapshot = newIDs
        let delta = newIDs.count - sequence.items.count
        let change = delta == 0 ? "changed" : (delta > 0 ? "gained \(delta)" : "lost \(-delta)")
        showNotice("Album \(change) photo\(abs(delta) == 1 ? "" : "s") — updates apply after this cycle")
        AlbumLoopLog.playback.info("Album changed: \(sequence.items.count) → \(newIDs.count); deferred to cycle end")
    }

    // MARK: Core state machine

    private func advance(byUser: Bool) {
        guard var sequence else { return }
        cancelSlideTimer()
        let step = sequence.advance()
        self.sequence = sequence
        switch step {
        case .advanced:
            break
        case .wrapped(let completedCycle):
            let report = makeReport(cycle: completedCycle)
            lastCycleReport = report
            AlbumLoopLog.playback.info("Cycle \(completedCycle) complete: \(report.summary, privacy: .public)")
            resetCycleTracking()
            if report.nothingCouldLoad {
                fail("None of the \(report.total) photos could be displayed. Check the network connection and iCloud Photos on this Apple TV, then try again.")
                return
            }
            if let pendingSnapshot {
                applySnapshot(pendingSnapshot)
                self.pendingSnapshot = nil
                if self.sequence == nil { return }
            } else if !report.isComplete {
                showNotice("Cycle \(completedCycle): \(report.summary)")
            }
        case .ended:
            let report = makeReport(cycle: sequence.cycle)
            lastCycleReport = report
            AlbumLoopLog.playback.info("Slideshow finished: \(report.summary, privacy: .public)")
            if report.nothingCouldLoad {
                fail("None of the \(report.total) photos could be displayed. Check the network connection and iCloud Photos on this Apple TV, then try again.")
                return
            }
            phase = .finished
            refreshWindow()
            publishDiagnostics()
            return
        }
        phase = .loading
        targetChanged(byNavigation: byUser)
    }

    private func applySnapshot(_ ids: [AssetID]) {
        guard let sequence else { return }
        guard !ids.isEmpty else {
            fail("This album no longer contains any photos.")
            return
        }
        let old = sequence.items.count
        self.sequence = sequence.rebuilt(with: ids, avoidingFirst: displayed?.id)
        total = ids.count
        showNotice("Album updated: \(old) → \(ids.count) photos")
    }

    /// Re-evaluates the slide playback is on after any change of position,
    /// buffer state, or retry.
    private func targetChanged(byNavigation: Bool) {
        guard let sequence, let buffer else { return }
        targetPosition = sequence.position
        cycle = sequence.cycle
        refreshWindow()

        let id = sequence.currentID
        if let displayed, displayed.cycle == sequence.cycle, displayed.position == sequence.position,
           displayed.id == id {
            phase = .showing
            startSlideTimerIfNeeded()
            publishDiagnostics()
            return
        }

        switch buffer.status(for: id) {
        case .ready:
            show(id)
        case .failed(let failure):
            if failure.kind == .notFound || failure.kind == .unsupported {
                // The photo was deleted or changed type after the snapshot. Record and move on.
                if !removedThisCycle.contains(id) { removedThisCycle.append(id) }
                AlbumLoopLog.playback.notice("Photo \(id.logToken, privacy: .public) no longer available; skipping")
                advance(byUser: false)
                return
            }
            if byNavigation {
                // Returning to a photo that failed earlier: try it again rather than
                // immediately showing an error.
                buffer.retry(id)
                phase = .loading
                updateTargetLoadingState()
            } else {
                phase = .stalled(failure)
            }
        case .absent, .queued, .loading, .waitingToRetry:
            phase = .loading
            updateTargetLoadingState()
        }
        publishDiagnostics()
    }

    private func show(_ id: AssetID) {
        guard let sequence, let buffer, let image = buffer.image(for: id) else { return }
        displayed = DisplayedSlide(id: id, image: image, cycle: sequence.cycle, position: sequence.position)
        displayedThisCycle.insert(id)
        skippedThisCycle.removeAll { $0 == id }
        targetProgress = nil
        isRetryingTarget = false
        phase = .showing
        remainingSlideTime = nil
        refreshWindow()
        startSlideTimerIfNeeded()
        publishDiagnostics()
    }

    private func handle(_ event: ImageBuffer.Event, session: Int) {
        // Events from a previous session can still be delivered while tearing down.
        guard session == sessionID, let sequence else { return }
        switch event {
        case .ready(let id):
            if id == sequence.currentID, phase == .loading {
                show(id)
            }
        case .failed(let id, _):
            if id == sequence.currentID, phase == .loading {
                targetChanged(byNavigation: false)
            }
        case .started(let id, _), .progress(let id, _), .retrying(let id, _, _):
            if id == sequence.currentID {
                updateTargetLoadingState()
            }
        }
        publishDiagnostics()
    }

    private func updateTargetLoadingState() {
        guard let sequence, let buffer else { return }
        switch buffer.status(for: sequence.currentID) {
        case .loading(_, let progress):
            targetProgress = progress > 0 ? progress : nil
            isRetryingTarget = false
        case .waitingToRetry:
            targetProgress = nil
            isRetryingTarget = true
        default:
            targetProgress = nil
            isRetryingTarget = false
        }
    }

    private func refreshWindow() {
        guard let sequence, let buffer else { return }
        let finished = phase == .finished
        buffer.setWindow(
            needed: sequence.currentID,
            ahead: finished ? [] : sequence.upcoming(bufferConfiguration.prefetchAhead),
            behind: sequence.recent(bufferConfiguration.keepBehind),
            onScreen: displayed?.id
        )
    }

    // MARK: Slide timer

    private func startSlideTimerIfNeeded() {
        guard phase == .showing, !isPaused, slideTimer == nil else { return }
        let duration = remainingSlideTime ?? settings.slideDuration
        remainingSlideTime = nil
        let session = sessionID
        timerStartedAt = scheduler.now - (settings.slideDuration - duration)
        slideTimer = scheduler.schedule(after: duration) { [weak self] in
            self?.slideTimerFired(session: session)
        }
    }

    private func slideTimerFired(session: Int) {
        guard session == sessionID, phase == .showing, !isPaused else { return }
        slideTimer = nil
        timerStartedAt = nil
        advance(byUser: false)
    }

    private func cancelSlideTimer() {
        slideTimer?.cancel()
        slideTimer = nil
        timerStartedAt = nil
        remainingSlideTime = nil
    }

    // MARK: Helpers

    private func fail(_ message: String) {
        cancelSlideTimer()
        buffer?.reset()
        phase = .failed(message)
        AlbumLoopLog.playback.error("Playback failed: \(message, privacy: .public)")
        publishDiagnostics()
    }

    private func makeReport(cycle: Int) -> CycleReport {
        let total = sequence?.count ?? 0
        return CycleReport(
            cycle: cycle,
            total: total,
            displayed: displayedThisCycle.count,
            skippedUnavailable: skippedThisCycle,
            removedFromLibrary: removedThisCycle
        )
    }

    private func resetCycleTracking() {
        displayedThisCycle = []
        skippedThisCycle = []
        removedThisCycle = []
    }

    private func showNotice(_ text: String) {
        notice = text
        noticeTimer?.cancel()
        noticeTimer = scheduler.schedule(after: .seconds(6)) { [weak self] in
            self?.notice = nil
            self?.noticeTimer = nil
        }
    }

    private func publishDiagnostics() {
        var value = PlaybackDiagnostics()
        value.sessionID = sessionID
        value.cycle = cycle
        value.position = sequence == nil ? 0 : targetPosition + 1
        value.total = total
        value.displayedThisCycle = displayedThisCycle.count
        value.skippedThisCycle = skippedThisCycle.count
        value.removedThisCycle = removedThisCycle.count
        value.buffer = buffer?.currentStats ?? BufferStats()
        value.recentRequests = buffer?.recentRequests ?? []
        if value != diagnostics {
            diagnostics = value
        }
    }

    // MARK: Test and diagnostics access

    /// The identifiers of the running sequence in current-cycle playback order.
    public var currentCycleIDs: [AssetID] { sequence?.currentCycleIDs ?? [] }
    public var currentTargetID: AssetID? { sequence?.currentID }
    public var imageBuffer: ImageBuffer? { buffer }
}
