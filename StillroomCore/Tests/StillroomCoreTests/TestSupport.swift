import Foundation
import Testing
@testable import StillroomCore

/// Scheduler whose clock only moves when a test calls `advance(by:)`.
@MainActor
final class ManualScheduler: Scheduling {
    private struct Item {
        let serial: Int
        let due: Duration
        let action: @MainActor () -> Void
        let work: ScheduledWork
    }

    private(set) var now: Duration = .zero
    private var items: [Item] = []
    private var serial = 0

    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> ScheduledWork {
        serial += 1
        let id = serial
        let work = ScheduledWork { [weak self] in
            self?.items.removeAll { $0.serial == id }
        }
        items.append(Item(serial: id, due: now + max(.zero, delay), action: action, work: work))
        return work
    }

    /// Moves time forward, firing due work in order (including work scheduled while firing).
    func advance(by delta: Duration) {
        let end = now + delta
        while let next = items.filter({ $0.due <= end }).min(by: { ($0.due, $0.serial) < ($1.due, $1.serial) }) {
            items.removeAll { $0.serial == next.serial }
            now = next.due
            next.action()
        }
        now = end
    }

    var pendingCount: Int { items.count }
}

/// Image provider whose requests stay pending until the test resolves them.
final class FakeImageProvider: ImageProviding, @unchecked Sendable {
    private struct Request {
        let serial: Int
        let id: AssetID
        var continuation: CheckedContinuation<LoadedImage, any Error>?
        var progress: (@Sendable (Double) -> Void)?
        var cancelled = false
    }

    private let lock = NSLock()
    private var requests: [Int: Request] = [:]
    private var serial = 0
    private var _log: [AssetID] = []
    private var _inFlight = 0
    private var _maxInFlight = 0
    private var _cancelledCount = 0
    private var _autoComplete = false
    private var _honorsCancellation = true

    let byteCost: Int

    init(byteCost: Int = 40_000, autoComplete: Bool = false) {
        self.byteCost = byteCost
        self._autoComplete = autoComplete
    }

    /// When false, a cancelled request stays pending so the test can deliver a late result.
    var honorsCancellation: Bool {
        get { lock.withLock { _honorsCancellation } }
        set { lock.withLock { _honorsCancellation = newValue } }
    }

    var autoComplete: Bool {
        get { lock.withLock { _autoComplete } }
        set { lock.withLock { _autoComplete = newValue } }
    }

    var requestLog: [AssetID] { lock.withLock { _log } }
    var maxInFlight: Int { lock.withLock { _maxInFlight } }
    var inFlight: Int { lock.withLock { _inFlight } }
    var cancelledCount: Int { lock.withLock { _cancelledCount } }

    var pendingIDs: [AssetID] {
        lock.withLock {
            requests.values.filter { $0.continuation != nil && !$0.cancelled }.sorted { $0.serial < $1.serial }.map(\.id)
        }
    }

    func requestCount(for id: AssetID) -> Int {
        lock.withLock { _log.filter { $0 == id }.count }
    }

    func makeImage() -> LoadedImage {
        LoadedImage(placeholderPixelSize: PixelSize(width: 100, height: 100), byteCost: byteCost)
    }

    func loadImage(
        for id: AssetID,
        targetPixelSize: PixelSize,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> LoadedImage {
        let (serial, auto) = lock.withLock { () -> (Int, Bool) in
            serial += 1
            _log.append(id)
            return (serial, _autoComplete)
        }
        if auto {
            return makeImage()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let alreadyCancelled = lock.withLock { () -> Bool in
                    if Task.isCancelled && _honorsCancellation { return true }
                    requests[serial] = Request(serial: serial, id: id, continuation: continuation, progress: progress)
                    _inFlight += 1
                    _maxInFlight = max(_maxInFlight, _inFlight)
                    return false
                }
                if alreadyCancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let continuation = lock.withLock { () -> CheckedContinuation<LoadedImage, any Error>? in
                _cancelledCount += 1
                guard var request = requests[serial] else { return nil }
                request.cancelled = true
                if _honorsCancellation {
                    requests[serial] = nil
                    _inFlight -= 1
                    return request.continuation
                }
                requests[serial] = request
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Resolves the oldest outstanding request for `id`. Returns false if none exists.
    @discardableResult
    func resolve(_ id: AssetID, with result: Result<LoadedImage, any Error>, includeCancelled: Bool = false) -> Bool {
        let continuation = lock.withLock { () -> CheckedContinuation<LoadedImage, any Error>? in
            guard let request = requests.values
                .filter({ $0.id == id && (includeCancelled || !$0.cancelled) })
                .min(by: { $0.serial < $1.serial })
            else { return nil }
            requests[request.serial] = nil
            _inFlight -= 1
            return request.continuation
        }
        guard let continuation else { return false }
        continuation.resume(with: result)
        return true
    }

    func sendProgress(_ id: AssetID, _ fraction: Double) {
        let handler = lock.withLock { requests.values.first { $0.id == id && !$0.cancelled }?.progress }
        handler?(fraction)
    }

    func hasPending(_ id: AssetID, includeCancelled: Bool = false) -> Bool {
        lock.withLock { requests.values.contains { $0.id == id && (includeCancelled || !$0.cancelled) } }
    }
}

extension FakeImageProvider {
    /// Waits for a request for `id` to arrive, then completes it successfully.
    @MainActor
    func succeed(_ id: AssetID, sourceLocation: SourceLocation = #_sourceLocation) async {
        await waitUntil(sourceLocation: sourceLocation) { self.hasPending(id) }
        resolve(id, with: .success(makeImage()))
    }

    @MainActor
    func fail(_ id: AssetID, _ failure: ImageLoadFailure, sourceLocation: SourceLocation = #_sourceLocation) async {
        await waitUntil(sourceLocation: sourceLocation) { self.hasPending(id) }
        resolve(id, with: .failure(failure))
    }
}

/// Polls `condition` on the main actor until it holds, recording an issue on timeout.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(3),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @MainActor () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now > deadline {
            Issue.record("Timed out waiting for condition", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

/// Gives in-flight tasks a chance to run when a test expects nothing to change.
@MainActor
func settle() async {
    for _ in 0..<20 {
        try? await Task.sleep(for: .milliseconds(1))
    }
}

func ids(_ count: Int, prefix: String = "a") -> [AssetID] {
    (0..<count).map { AssetID("\(prefix)\($0)") }
}

let networkError = ImageLoadFailure(.network, "The Internet connection appears to be offline.")
