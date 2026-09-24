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

/// One photo on the displayed slide.
public struct DisplayedPhoto: Sendable {
    public let id: AssetID
    public let image: LoadedImage
}

/// The slide currently on screen: one photo, or two when vertical photos are paired.
public struct DisplayedSlide: Sendable {
    public let photos: [DisplayedPhoto]
    public let cycle: Int
    /// 0-based index of the slide in the cycle.
    public let slideIndex: Int
    /// 0-based photo position (in the cycle) of the slide's first photo.
    public let position: Int

    /// The first photo on the slide.
    public var id: AssetID { photos[0].id }
    public var image: LoadedImage { photos[0].image }
    public var ids: [AssetID] { photos.map(\.id) }
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
        /// Waiting for the target slide's images. Any previous slide stays on screen.
        case loading
        /// The target slide is on screen.
        case showing
        /// A photo on the target slide failed after automatic retries; the user can retry or skip.
        case stalled(ImageLoadFailure)
        /// Looping is off and every slide has been visited.
        case finished
        /// Playback cannot continue (for example, nothing in the album could be loaded).
        case failed(String)
    }

    /// Why the target slide changed; decides how failures on it are handled.
    private enum Navigation {
        /// Not a move (start, retry, image event).
        case none
        /// Automatic advance (timer, or passing a removed photo).
        case automatic
        case userForward
        case userBackward

        var isUser: Bool { self == .userForward || self == .userBackward }
    }

    // MARK: Observable state

    public private(set) var phase: Phase = .idle
    public private(set) var isPaused = false
    public private(set) var displayed: DisplayedSlide?
    /// 0-based photo position of the slide playback is on (which may still be loading).
    public private(set) var targetPosition = 0
    /// Number of photos on the target slide (2 for a vertical pair).
    public private(set) var targetSlideSize = 1
    public private(set) var total = 0
    public private(set) var cycle = 1
    /// Download progress for the target slide while loading, if known.
    public private(set) var targetProgress: Double?
    /// True while a photo on the target slide is between automatic retries.
    public private(set) var isRetryingTarget = false
    /// Highest attempt number among the target slide's photos that are loading (0 if none).
    public private(set) var targetAttempt = 0
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

    /// How far the on-screen slide is through its display time. Not observable;
    /// read it from a `TimelineView` to drive motion such as panning. Freezes
    /// while paused and holds at the full duration while the next slide loads.
    public var slideElapsed: Duration {
        if let timerStartedAt {
            return min(settings.slideDuration, scheduler.now - timerStartedAt)
        }
        if let remainingSlideTime {
            return settings.slideDuration - remainingSlideTime
        }
        return phase == .showing ? .zero : settings.slideDuration
    }

    /// How long playback has been waiting for the current target slide, or nil
    /// if it isn't waiting. Not observable; read it from a `TimelineView`.
    public var targetLoadingElapsed: Duration? {
        loadingSince.map { scheduler.now - $0 }
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
    private var pendingSnapshot: (ids: [AssetID], pairable: Set<AssetID>)?
    private var wasPlayingBeforeBackground = false
    /// When playback started waiting for the slide identified by `loadingKey`.
    private var loadingSince: Duration?
    private var loadingKey: String?

    private var displayedThisCycle: Set<AssetID> = []
    private var skippedThisCycle: [AssetID] = []
    private var removedThisCycle: [AssetID] = []
    /// Skipped and removed photos, left off their slides for the rest of the cycle.
    private var excludedThisCycle: Set<AssetID> = []

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
    ///
    /// - Parameter pairable: Photos that may share a slide with an adjacent
    ///   pairable photo (vertical photos when side-by-side pairing is on).
    public func start(assetIDs: [AssetID], pairable: Set<AssetID> = [], settings: SlideshowSettings? = nil) {
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
            seed: seedSource(),
            pairable: pairable
        )
        total = assetIDs.count
        phase = .loading
        AlbumLoopLog.playback.info(
            "Session \(session) started: \(assetIDs.count) photos, \(self.sequence?.slideCount ?? 0) slides, order \(self.settings.order.rawValue)"
        )
        targetChanged(.none)
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
        targetSlideSize = 1
        total = 0
        cycle = 1
        targetProgress = nil
        isRetryingTarget = false
        targetAttempt = 0
        loadingSince = nil
        loadingKey = nil
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
        AlbumLoopLog.playback.info("Paused at photo \(targetPosition + 1)")
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
        AlbumLoopLog.playback.info("Resumed at photo \(targetPosition + 1)")
        startSlideTimerIfNeeded()
    }

    /// Moves to the next slide in the playback sequence. While stalled on an
    /// unavailable photo this is an explicit skip and is recorded as such.
    public func next() {
        guard sequence != nil else { return }
        AlbumLoopLog.playback.info("User: next (from photo \(targetPosition + 1))")
        switch phase {
        case .stalled:
            skipCurrent()
        case .loading, .showing:
            advance(navigation: .userForward)
        case .idle, .finished, .failed:
            break
        }
    }

    /// Moves back one slide within the current cycle.
    public func previous() {
        guard sequence != nil else { return }
        AlbumLoopLog.playback.info("User: previous (from photo \(targetPosition + 1))")
        switch phase {
        case .loading, .showing, .stalled, .finished:
            retreat()
        case .idle, .failed:
            break
        }
    }

    /// Tries the stalled photos again with a fresh set of attempts.
    public func retryCurrent() {
        guard let sequence, let buffer else { return }
        AlbumLoopLog.playback.info("User: retry photo \(targetPosition + 1)")
        if case .stalled = phase {
            phase = .loading
        }
        for id in sequence.currentIDs {
            buffer.retry(id)
        }
        targetChanged(.none)
    }

    /// Explicitly skips the photos on this slide that could not be loaded and
    /// records them. A paired photo that did load is still shown.
    public func skipCurrent() {
        guard let sequence, let buffer, case .stalled = phase else { return }
        let failedIDs = sequence.currentIDs.filter { id in
            if case .failed = buffer.status(for: id) { true } else { false }
        }
        for id in failedIDs {
            if !skippedThisCycle.contains(id) {
                skippedThisCycle.append(id)
            }
            excludedThisCycle.insert(id)
            AlbumLoopLog.playback.notice("User skipped unavailable photo \(id.logToken)")
        }
        if activeIDs(of: sequence).isEmpty {
            advance(navigation: .userForward)
        } else {
            phase = .loading
            targetChanged(.none)
        }
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
        let snapshot = pendingSnapshot ?? (sequence.items, sequence.pairable)
        start(assetIDs: snapshot.ids, pairable: snapshot.pairable)
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
                targetChanged(.none)
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
        guard let sequence else { return }
        AlbumLoopLog.playback.info("App entered background at photo \(targetPosition + 1)")
        wasPlayingBeforeBackground = !isPaused
        pause()
        buffer?.setWindow(needed: sequence.currentIDs, ahead: [], behind: [], onScreen: displayed?.ids ?? [])
        publishDiagnostics()
    }

    public func enterForeground() {
        guard sequence != nil else { return }
        AlbumLoopLog.playback.info("App returned to foreground at photo \(targetPosition + 1)")
        refreshWindow()
        if wasPlayingBeforeBackground {
            resume()
        }
        wasPlayingBeforeBackground = false
    }

    /// Supplies a fresh snapshot after the album changed in the library.
    /// The running cycle is never rebuilt; the new snapshot applies from the next cycle.
    public func albumContentsChanged(_ newIDs: [AssetID], pairable: Set<AssetID> = []) {
        guard let sequence, newIDs != sequence.items else { return }
        pendingSnapshot = (newIDs, pairable)
        let delta = newIDs.count - sequence.items.count
        let change = delta == 0 ? "changed" : (delta > 0 ? "gained \(delta)" : "lost \(-delta)")
        showNotice("Album \(change) photo\(abs(delta) == 1 ? "" : "s") — updates apply after this cycle")
        AlbumLoopLog.playback.info("Album changed: \(sequence.items.count) → \(newIDs.count); deferred to cycle end")
    }

    // MARK: Core state machine

    private func advance(navigation: Navigation) {
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
            AlbumLoopLog.playback.info("Cycle \(completedCycle) complete: \(report.summary)")
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
            AlbumLoopLog.playback.info("Slideshow finished: \(report.summary)")
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
        targetChanged(navigation)
    }

    private func retreat() {
        guard var sequence else { return }
        guard sequence.retreat() else {
            showNotice("Start of this cycle")
            return
        }
        self.sequence = sequence
        cancelSlideTimer()
        phase = .loading
        targetChanged(.userBackward)
    }

    private func applySnapshot(_ snapshot: (ids: [AssetID], pairable: Set<AssetID>)) {
        guard let sequence else { return }
        guard !snapshot.ids.isEmpty else {
            fail("This album no longer contains any photos.")
            return
        }
        let old = sequence.items.count
        self.sequence = sequence.rebuilt(with: snapshot.ids, pairable: snapshot.pairable, avoidingFirst: displayed?.id)
        total = snapshot.ids.count
        showNotice("Album updated: \(old) → \(snapshot.ids.count) photos")
    }

    /// Photos on the current slide that haven't been skipped or removed this cycle.
    private func activeIDs(of sequence: PlaybackSequence) -> [AssetID] {
        sequence.currentIDs.filter { !excludedThisCycle.contains($0) }
    }

    /// Re-evaluates the slide playback is on after any change of position,
    /// buffer state, or retry.
    private func targetChanged(_ navigation: Navigation) {
        guard let sequence, let buffer else { return }
        targetPosition = sequence.position
        targetSlideSize = sequence.currentIDs.count
        cycle = sequence.cycle
        refreshWindow()

        var ids = activeIDs(of: sequence)
        if ids.isEmpty {
            // Every photo on this slide was skipped or removed earlier this cycle.
            let skipped = sequence.currentIDs.filter { skippedThisCycle.contains($0) }
            if navigation.isUser, !skipped.isEmpty {
                // The user came back to it on purpose: try the skipped photos again.
                for id in skipped {
                    excludedThisCycle.remove(id)
                    buffer.retry(id)
                }
                ids = skipped
            } else {
                passOver(navigation)
                return
            }
        }

        if let displayed, displayed.cycle == sequence.cycle, displayed.slideIndex == sequence.slideIndex,
           displayed.ids == ids {
            phase = .showing
            startSlideTimerIfNeeded()
            publishDiagnostics()
            return
        }

        var failure: ImageLoadFailure?
        var allReady = true
        var removedAny = false
        for id in ids {
            switch buffer.status(for: id) {
            case .ready:
                continue
            case .failed(let error) where error.kind == .notFound || error.kind == .unsupported:
                // Deleted or changed type after the snapshot. Record and leave it off the slide.
                if !removedThisCycle.contains(id) { removedThisCycle.append(id) }
                excludedThisCycle.insert(id)
                removedAny = true
                AlbumLoopLog.playback.notice("Photo \(id.logToken) no longer available; skipping")
            case .failed(let error):
                allReady = false
                if navigation != .none {
                    // Arriving at a photo that failed earlier (while prefetching, or
                    // before the user navigated away): conditions may have changed,
                    // so give it a fresh round of retries before showing an error.
                    buffer.retry(id)
                } else {
                    failure = failure ?? error
                }
            case .absent, .queued, .loading, .waitingToRetry:
                allReady = false
            }
        }

        if removedAny {
            targetChanged(navigation)
            return
        }
        if allReady {
            show(ids)
            return
        }
        if let failure {
            phase = .stalled(failure)
            AlbumLoopLog.playback.notice(
                "Stalled on photo \(sequence.position + 1) after \(elapsedText()): \(failure.description)"
            )
        } else {
            phase = .loading
            let key = "\(sequence.cycle)-\(sequence.slideIndex)"
            if loadingKey != key {
                loadingKey = key
                loadingSince = scheduler.now
                AlbumLoopLog.playback.info(
                    "Waiting for photo \(sequence.position + 1) of \(sequence.count) [\(tokens(ids))]"
                )
            }
            updateTargetLoadingState()
        }
        publishDiagnostics()
    }

    private func tokens(_ ids: [AssetID]) -> String {
        ids.map(\.logToken).joined(separator: ",")
    }

    private func elapsedText() -> String {
        guard let elapsed = targetLoadingElapsed else { return "0 s" }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return String(format: "%.1f s", seconds)
    }

    /// Moves past a slide with nothing left to show, in the direction of travel.
    private func passOver(_ navigation: Navigation) {
        if navigation == .userBackward, var sequence, sequence.retreat() {
            self.sequence = sequence
            targetChanged(.userBackward)
        } else {
            advance(navigation: navigation == .userBackward ? .userForward : navigation)
        }
    }

    private func show(_ ids: [AssetID]) {
        guard let sequence, let buffer else { return }
        let photos = ids.compactMap { id in buffer.image(for: id).map { DisplayedPhoto(id: id, image: $0) } }
        guard photos.count == ids.count else { return }
        displayed = DisplayedSlide(
            photos: photos,
            cycle: sequence.cycle,
            slideIndex: sequence.slideIndex,
            position: sequence.position
        )
        displayedThisCycle.formUnion(ids)
        skippedThisCycle.removeAll { ids.contains($0) }
        AlbumLoopLog.playback.info(
            "Showing photo \(sequence.position + 1) of \(sequence.count), cycle \(sequence.cycle) [\(tokens(ids))]"
                + (loadingSince == nil ? " (was ready)" : " after waiting \(elapsedText())")
        )
        loadingSince = nil
        loadingKey = nil
        targetProgress = nil
        isRetryingTarget = false
        targetAttempt = 0
        phase = .showing
        remainingSlideTime = nil
        refreshWindow()
        startSlideTimerIfNeeded()
        publishDiagnostics()
    }

    private func handle(_ event: ImageBuffer.Event, session: Int) {
        // Events from a previous session can still be delivered while tearing down.
        guard session == sessionID, let sequence else { return }
        let targetIDs = activeIDs(of: sequence)
        switch event {
        case .ready(let id), .failed(let id, _):
            if targetIDs.contains(id), phase == .loading {
                targetChanged(.none)
            }
        case .started(let id, _), .progress(let id, _), .retrying(let id, _, _):
            if targetIDs.contains(id) {
                updateTargetLoadingState()
            }
        }
        publishDiagnostics()
    }

    private func updateTargetLoadingState() {
        guard let sequence, let buffer else { return }
        var progress: [Double] = []
        var retrying = false
        var attempt = 0
        for id in activeIDs(of: sequence) {
            switch buffer.status(for: id) {
            case .loading(let current, let fraction):
                progress.append(fraction)
                attempt = max(attempt, current)
            case .waitingToRetry(let current, _):
                retrying = true
                attempt = max(attempt, current)
            case .ready:
                progress.append(1)
            default:
                progress.append(0)
            }
        }
        let average = progress.isEmpty ? 0 : progress.reduce(0, +) / Double(progress.count)
        targetProgress = average > 0 && average < 1 ? average : nil
        isRetryingTarget = retrying
        targetAttempt = attempt
    }

    private func refreshWindow() {
        guard let sequence, let buffer else { return }
        let finished = phase == .finished
        buffer.setWindow(
            needed: activeIDs(of: sequence).isEmpty ? sequence.currentIDs : activeIDs(of: sequence),
            ahead: finished ? [] : sequence.upcoming(bufferConfiguration.prefetchAhead),
            behind: sequence.recent(bufferConfiguration.keepBehind),
            onScreen: displayed?.ids ?? []
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
        advance(navigation: .automatic)
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
        AlbumLoopLog.playback.error("Playback failed: \(message)")
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
        excludedThisCycle = []
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
    /// The photos on the slide playback is on.
    public var currentTargetIDs: [AssetID] { sequence?.currentIDs ?? [] }
    public var imageBuffer: ImageBuffer? { buffer }
    /// Automatic attempts per photo before playback stalls.
    public var maxAttempts: Int { bufferConfiguration.maxAttempts }
}
