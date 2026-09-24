import Foundation

/// App-owned, bounded rolling buffer of decoded slideshow images.
///
/// The buffer only holds a small window around the playback position. It never
/// defines what the slideshow contains; `PlaybackSequence` does. Every load is
/// tagged with a unique request token, so callbacks that arrive after a
/// cancellation, navigation, or reset are recognised as stale and ignored.
@MainActor
public final class ImageBuffer {
    public struct Configuration: Sendable, Equatable {
        /// Upcoming slides to prefetch.
        public var prefetchAhead: Int
        /// Previously shown slides to keep for back navigation.
        public var keepBehind: Int
        /// Maximum simultaneous image requests.
        public var maxConcurrentLoads: Int
        /// Upper bound for decoded image bytes (ready plus in-flight estimate).
        public var maxDecodedBytes: Int
        /// Backoff before each automatic retry; attempts = count + 1.
        public var retryDelays: [Duration]
        /// Cancel an attempt if no progress arrives for this long.
        public var stallTimeout: Duration
        /// Cancel an attempt that runs longer than this even with progress.
        public var attemptTimeout: Duration
        /// Upper bound for one decoded image, used for memory admission. Defaults
        /// to a screen-sized image; larger when images are rendered bigger than
        /// the screen (for example for panning).
        public var estimatedImageBytes: Int?

        public init(
            prefetchAhead: Int = 3,
            keepBehind: Int = 2,
            maxConcurrentLoads: Int = 2,
            maxDecodedBytes: Int = 300_000_000,
            retryDelays: [Duration] = [.seconds(2), .seconds(6), .seconds(15)],
            stallTimeout: Duration = .seconds(30),
            attemptTimeout: Duration = .seconds(120),
            estimatedImageBytes: Int? = nil
        ) {
            self.prefetchAhead = prefetchAhead
            self.keepBehind = keepBehind
            self.maxConcurrentLoads = maxConcurrentLoads
            self.maxDecodedBytes = maxDecodedBytes
            self.retryDelays = retryDelays
            self.stallTimeout = stallTimeout
            self.attemptTimeout = attemptTimeout
            self.estimatedImageBytes = estimatedImageBytes
        }

        public var maxAttempts: Int { retryDelays.count + 1 }
    }

    public enum Status: Equatable, Sendable {
        case absent
        case queued
        case loading(attempt: Int, progress: Double)
        case waitingToRetry(attempt: Int, lastFailure: ImageLoadFailure)
        case ready
        case failed(ImageLoadFailure)
    }

    public enum Event: Sendable {
        case started(AssetID, attempt: Int)
        case ready(AssetID)
        case failed(AssetID, ImageLoadFailure)
        case progress(AssetID, Double)
        case retrying(AssetID, attempt: Int, after: ImageLoadFailure)
    }

    private struct Entry {
        var status: Status = .queued
        var image: LoadedImage?
        /// Attempts started for the current run (reset by an explicit retry).
        var attempts = 0
        /// Token of the in-flight attempt; 0 when none.
        var token: UInt64 = 0
        var task: Task<Void, Never>?
        var startedAt: Duration = .zero
        var lastProgressAt: Duration = .zero
        var watchdog: ScheduledWork?
        var retryTimer: ScheduledWork?

        var isLoading: Bool {
            if case .loading = status { true } else { false }
        }
    }

    public private(set) var configuration: Configuration
    public let targetPixelSize: PixelSize
    public var onEvent: (@MainActor (Event) -> Void)?

    private let provider: any ImageProviding
    private let scheduler: any Scheduling
    private var entries: [AssetID: Entry] = [:]
    /// Desired identifiers, highest priority first.
    private var priorities: [AssetID] = []
    /// Identifiers that must never be evicted (the needed slide and the one on screen).
    private var protected: Set<AssetID> = []
    private var nextToken: UInt64 = 1
    private var stats = BufferStats()
    private var records: [RequestRecord] = []
    private let recordLimit = 12

    public init(
        provider: any ImageProviding,
        scheduler: any Scheduling,
        targetPixelSize: PixelSize,
        configuration: Configuration = Configuration()
    ) {
        self.provider = provider
        self.scheduler = scheduler
        self.targetPixelSize = targetPixelSize
        self.configuration = configuration
    }

    // MARK: Queries

    public func status(for id: AssetID) -> Status {
        entries[id]?.status ?? .absent
    }

    public func image(for id: AssetID) -> LoadedImage? {
        entries[id]?.image
    }

    public var bufferedIDs: Set<AssetID> {
        Set(entries.compactMap { $0.value.image == nil ? nil : $0.key })
    }

    public var currentStats: BufferStats {
        var result = stats
        result.ready = 0
        result.loading = 0
        result.pending = 0
        result.failed = 0
        result.decodedBytes = 0
        for entry in entries.values {
            switch entry.status {
            case .ready: result.ready += 1
            case .loading: result.loading += 1
            case .queued, .waitingToRetry: result.pending += 1
            case .failed: result.failed += 1
            case .absent: break
            }
            result.decodedBytes += entry.image?.byteCost ?? 0
        }
        result.byteBudget = configuration.maxDecodedBytes
        return result
    }

    public var recentRequests: [RequestRecord] { records }

    // MARK: Window management

    /// Declares which images are wanted, in priority order.
    ///
    /// - Parameters:
    ///   - needed: The photos on the slide playback is waiting for or showing. Always loaded first.
    ///   - ahead: Upcoming photos in playback order.
    ///   - behind: Recent photos for back navigation.
    ///   - onScreen: The photos currently displayed, which must not be evicted.
    ///
    /// Anything not listed is cancelled or evicted.
    public func setWindow(needed: [AssetID], ahead: [AssetID], behind: [AssetID], onScreen: [AssetID]) {
        var ordered: [AssetID] = []
        var seen: Set<AssetID> = []
        func add(_ id: AssetID) {
            guard seen.insert(id).inserted else { return }
            ordered.append(id)
        }
        needed.forEach(add)
        onScreen.forEach(add)
        ahead.prefix(configuration.prefetchAhead).forEach(add)
        behind.prefix(configuration.keepBehind).forEach(add)

        priorities = ordered
        protected = Set(needed + onScreen)

        for id in entries.keys where !seen.contains(id) {
            discard(id)
        }
        for id in ordered where entries[id] == nil {
            entries[id] = Entry()
        }
        enforceByteBudget()
        pump()
    }

    /// Single-photo convenience for `setWindow(needed:ahead:behind:onScreen:)`.
    public func setWindow(needed: AssetID?, ahead: [AssetID], behind: [AssetID], onScreen: AssetID?) {
        setWindow(
            needed: needed.map { [$0] } ?? [],
            ahead: ahead,
            behind: behind,
            onScreen: onScreen.map { [$0] } ?? []
        )
    }

    /// Resets a failed or waiting image and loads it again with a fresh set of attempts.
    public func retry(_ id: AssetID) {
        guard var entry = entries[id] else { return }
        switch entry.status {
        case .failed, .waitingToRetry:
            entry.retryTimer?.cancel()
            entry.retryTimer = nil
            entry.attempts = 0
            entry.status = .queued
            entries[id] = entry
            pump()
        case .absent, .queued, .loading, .ready:
            break
        }
    }

    /// Retries every failed or backing-off image, e.g. after the network returns.
    public func retryAllFailed() {
        for (id, entry) in entries {
            switch entry.status {
            case .failed(let failure) where failure.isRetryable:
                retry(id)
            case .waitingToRetry:
                retry(id)
            default:
                break
            }
        }
    }

    /// Drops everything except protected images and tightens the byte budget.
    public func handleMemoryPressure() {
        let floor = estimatedImageBytes * 3
        configuration.maxDecodedBytes = max(floor, configuration.maxDecodedBytes / 2)
        configuration.prefetchAhead = max(1, configuration.prefetchAhead - 1)
        configuration.keepBehind = max(0, configuration.keepBehind - 1)
        for id in entries.keys where !protected.contains(id) {
            discard(id)
        }
        priorities.removeAll { !protected.contains($0) }
        AlbumLoopLog.loading.notice("Memory pressure: budget now \(self.configuration.maxDecodedBytes) bytes")
    }

    /// Cancels all work and forgets every image. Late callbacks are then stale.
    public func reset() {
        for id in Array(entries.keys) {
            discard(id)
        }
        priorities = []
        protected = []
    }

    // MARK: Loading

    private var estimatedImageBytes: Int {
        configuration.estimatedImageBytes ?? targetPixelSize.decodedByteEstimate
    }

    private func pump() {
        var loadingCount = entries.values.filter(\.isLoading).count
        for id in priorities {
            guard let entry = entries[id], entry.status == .queued else { continue }
            let isEssential = protected.contains(id)

            if loadingCount >= configuration.maxConcurrentLoads {
                // The needed image must not wait behind prefetches.
                guard isEssential, preemptLowestPriorityPrefetch() else { break }
                loadingCount -= 1
            }
            if !isEssential && !hasByteBudgetForAnotherLoad(loadingCount: loadingCount) {
                break
            }
            start(id)
            loadingCount += 1
        }
    }

    private func hasByteBudgetForAnotherLoad(loadingCount: Int) -> Bool {
        let readyBytes = entries.values.reduce(0) { $0 + ($1.image?.byteCost ?? 0) }
        let estimate = estimatedImageBytes
        return readyBytes + (loadingCount + 1) * estimate <= configuration.maxDecodedBytes
    }

    private func preemptLowestPriorityPrefetch() -> Bool {
        for id in priorities.reversed() where !protected.contains(id) {
            guard var entry = entries[id], entry.isLoading else { continue }
            entry.task?.cancel()
            entry.watchdog?.cancel()
            entry.task = nil
            entry.watchdog = nil
            entry.token = 0
            // A preempted prefetch does not use up an attempt.
            entry.attempts = max(0, entry.attempts - 1)
            entry.status = .queued
            entries[id] = entry
            AlbumLoopLog.loading.debug("Preempted prefetch \(id.logToken)")
            return true
        }
        return false
    }

    private func start(_ id: AssetID) {
        guard var entry = entries[id] else { return }
        let token = nextToken
        nextToken += 1
        entry.attempts += 1
        entry.token = token
        entry.status = .loading(attempt: entry.attempts, progress: 0)
        entry.startedAt = scheduler.now
        entry.lastProgressAt = scheduler.now
        if entry.attempts > 1 { stats.retries += 1 }

        let provider = self.provider
        let size = targetPixelSize
        let attempt = entry.attempts
        let onProgress: @Sendable (Double) -> Void = { [weak self] fraction in
            guard let self else { return }
            Task { @MainActor in
                self.progress(id: id, token: token, fraction: fraction)
            }
        }
        entry.task = Task { [weak self] in
            let result: Result<LoadedImage, any Error>
            do {
                let image = try await provider.loadImage(for: id, targetPixelSize: size, progress: onProgress)
                result = .success(image)
            } catch {
                result = .failure(error)
            }
            self?.finish(id: id, token: token, result: result)
        }
        entry.watchdog = scheduleWatchdog(id: id, token: token, after: configuration.stallTimeout)
        entries[id] = entry
        AlbumLoopLog.loading.info("Request \(id.logToken) attempt \(attempt)")
        onEvent?(.started(id, attempt: attempt))
    }

    private func progress(id: AssetID, token: UInt64, fraction: Double) {
        guard var entry = entries[id], entry.token == token, case .loading(let attempt, _) = entry.status else {
            return
        }
        entry.status = .loading(attempt: attempt, progress: min(1, max(0, fraction)))
        entry.lastProgressAt = scheduler.now
        entries[id] = entry
        onEvent?(.progress(id, fraction))
    }

    private func scheduleWatchdog(id: AssetID, token: UInt64, after delay: Duration) -> ScheduledWork {
        scheduler.schedule(after: delay) { [weak self] in
            self?.checkWatchdog(id: id, token: token)
        }
    }

    private func checkWatchdog(id: AssetID, token: UInt64) {
        guard var entry = entries[id], entry.token == token, entry.isLoading else { return }
        let now = scheduler.now
        let sinceProgress = now - entry.lastProgressAt
        let sinceStart = now - entry.startedAt
        let failure: ImageLoadFailure?
        if sinceStart >= configuration.attemptTimeout {
            failure = ImageLoadFailure(.timedOut, "The download took too long.")
        } else if sinceProgress >= configuration.stallTimeout {
            failure = ImageLoadFailure(.stalled, "The download stopped making progress.")
        } else {
            failure = nil
        }
        guard let failure else {
            let remaining = min(configuration.stallTimeout - sinceProgress, configuration.attemptTimeout - sinceStart)
            entry.watchdog = scheduleWatchdog(id: id, token: token, after: remaining)
            entries[id] = entry
            return
        }
        // Invalidate the token first so the cancelled task's late callback is stale.
        entry.task?.cancel()
        entry.task = nil
        entry.token = 0
        entries[id] = entry
        record(id: id, attempt: entry.attempts, startedAt: entry.startedAt, outcome: .failed(failure))
        handleFailure(id: id, failure: failure)
    }

    private func finish(id: AssetID, token: UInt64, result: Result<LoadedImage, any Error>) {
        guard var entry = entries[id], entry.token == token, entry.isLoading else {
            stats.staleCallbacks += 1
            AlbumLoopLog.loading.info("Ignored stale result for \(id.logToken)")
            return
        }
        entry.watchdog?.cancel()
        entry.watchdog = nil
        entry.task = nil
        entry.token = 0

        switch result {
        case .success(let image):
            entry.image = image
            entry.status = .ready
            entries[id] = entry
            stats.completedRequests += 1
            record(id: id, attempt: entry.attempts, startedAt: entry.startedAt, outcome: .succeeded)
            AlbumLoopLog.loading.info(
                "Loaded \(id.logToken) attempt \(entry.attempts) in \(Self.format(scheduler.now - entry.startedAt)), \(image.pixelSize.width)×\(image.pixelSize.height)"
            )
            enforceByteBudget()
            onEvent?(.ready(id))
            pump()
        case .failure(let error):
            entries[id] = entry
            if error is CancellationError {
                // Cancelled by someone other than this buffer; treat as retryable.
                record(id: id, attempt: entry.attempts, startedAt: entry.startedAt, outcome: .cancelled)
                handleFailure(id: id, failure: ImageLoadFailure(.other, "The request was cancelled."))
            } else {
                let failure = (error as? ImageLoadFailure) ?? ImageLoadFailure(.other, error.localizedDescription)
                record(id: id, attempt: entry.attempts, startedAt: entry.startedAt, outcome: .failed(failure))
                handleFailure(id: id, failure: failure)
            }
        }
    }

    private func handleFailure(id: AssetID, failure: ImageLoadFailure) {
        guard var entry = entries[id] else { return }
        stats.failedRequests += 1
        entry.watchdog?.cancel()
        entry.watchdog = nil
        let attempt = entry.attempts
        if failure.isRetryable, attempt < configuration.maxAttempts {
            let delay = configuration.retryDelays[attempt - 1]
            entry.status = .waitingToRetry(attempt: attempt, lastFailure: failure)
            entry.retryTimer = scheduler.schedule(after: delay) { [weak self] in
                self?.retryTimerFired(id: id)
            }
            entries[id] = entry
            AlbumLoopLog.loading.notice(
                "Attempt \(attempt) failed for \(id.logToken): \(failure.description); retrying"
            )
            onEvent?(.retrying(id, attempt: attempt, after: failure))
            pump()
        } else {
            entry.status = .failed(failure)
            entries[id] = entry
            AlbumLoopLog.loading.error(
                "Giving up on \(id.logToken) after \(attempt) attempts: \(failure.description)"
            )
            onEvent?(.failed(id, failure))
            pump()
        }
    }

    private func retryTimerFired(id: AssetID) {
        guard var entry = entries[id], case .waitingToRetry = entry.status else { return }
        entry.retryTimer = nil
        entry.status = .queued
        entries[id] = entry
        pump()
    }

    // MARK: Eviction

    private func discard(_ id: AssetID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.task?.cancel()
        entry.watchdog?.cancel()
        entry.retryTimer?.cancel()
        if entry.isLoading {
            record(id: id, attempt: entry.attempts, startedAt: entry.startedAt, outcome: .cancelled)
        }
    }

    /// Evicts the lowest-priority unprotected images until within budget.
    private func enforceByteBudget() {
        var total = entries.values.reduce(0) { $0 + ($1.image?.byteCost ?? 0) }
        guard total > configuration.maxDecodedBytes else { return }
        for id in priorities.reversed() where !protected.contains(id) {
            guard total > configuration.maxDecodedBytes else { break }
            guard let entry = entries[id], let image = entry.image else { continue }
            total -= image.byteCost
            discard(id)
            priorities.removeAll { $0 == id }
            AlbumLoopLog.loading.debug("Evicted \(id.logToken) for byte budget")
        }
    }

    static func format(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.2f s", seconds)
    }

    private func record(id: AssetID, attempt: Int, startedAt: Duration, outcome: RequestRecord.Outcome) {
        let record = RequestRecord(
            id: nextToken,
            assetToken: id.logToken,
            attempt: attempt,
            duration: scheduler.now - startedAt,
            outcome: outcome
        )
        nextToken += 1
        records.append(record)
        if records.count > recordLimit {
            records.removeFirst(records.count - recordLimit)
        }
    }
}
