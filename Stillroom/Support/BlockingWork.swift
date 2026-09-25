import Dispatch

/// Runs synchronous, potentially slow work (PhotoKit fetches, image decoding,
/// Vision) on Grand Central Dispatch instead of Swift's cooperative thread pool.
///
/// The cooperative pool has one thread per CPU core, which is only **two** on an
/// Apple TV HD. Blocking both with synchronous work stalls every `await` in the
/// app, including timers and the download watchdog. This froze slideshows on an
/// Apple TV HD when two Vision requests hung at once (2026-09-24).
enum BlockingWork {
    private static let fetchQueue = DispatchQueue(
        label: "Stillroom.PhotoKitFetch",
        qos: .userInitiated,
        attributes: .concurrent
    )

    static func run<T: Sendable>(
        qos: DispatchQoS.QoSClass = .userInitiated,
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            fetchQueue.async(qos: DispatchQoS(qosClass: qos, relativePriority: 0)) {
                continuation.resume(returning: work())
            }
        }
    }

    static func run<T: Sendable>(
        on queue: DispatchQueue,
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}
