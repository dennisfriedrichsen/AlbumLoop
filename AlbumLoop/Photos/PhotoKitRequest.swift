import Photos
import Synchronization
import UIKit

/// Bridges one callback-based `PHImageManager` image request to async/await.
///
/// PhotoKit may call the result handler several times (degraded previews, then
/// the final image), synchronously or asynchronously, or not at all after a
/// cancellation. This wrapper:
/// - ignores degraded results and waits for the final one,
/// - resumes the continuation exactly once,
/// - cancels the PhotoKit request when the calling task is cancelled, and
///   resumes with `CancellationError` even if PhotoKit never calls back.
enum PhotoKitRequest {
    /// The final (non-degraded) callback of a request.
    struct FinalResult: @unchecked Sendable {
        let image: UIImage?
        let error: (any Error)?
        /// PhotoKit reported that the full-quality data is only in iCloud.
        let isInCloud: Bool
    }

    static func requestImage(
        manager: PHImageManager,
        asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        options: PHImageRequestOptions
    ) async throws -> FinalResult {
        let state = RequestState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard state.attach(continuation) else { return }
                let requestID = manager.requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: contentMode,
                    options: options
                ) { image, info in
                    if (info?[PHImageCancelledKey] as? Bool) == true {
                        state.finish(.failure(CancellationError()))
                        return
                    }
                    let error = info?[PHImageErrorKey] as? any Error
                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if isDegraded && error == nil {
                        // A low-quality preview; the final result follows.
                        return
                    }
                    let isInCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                    state.finish(.success(FinalResult(image: image, error: error, isInCloud: isInCloud)))
                }
                state.setRequestID(requestID, manager: manager)
            }
        } onCancel: {
            state.cancel()
        }
    }
}

/// Thread-safe once-only state for a single PhotoKit request.
private final class RequestState: Sendable {
    private struct Storage {
        var continuation: CheckedContinuation<PhotoKitRequest.FinalResult, any Error>?
        var requestID: PHImageRequestID?
        var manager: PHImageManager?
        var cancelled = false
        var finished = false
    }

    private let storage = Mutex(Storage())

    /// Stores the continuation. Returns false (after resuming it) if already cancelled.
    func attach(_ continuation: CheckedContinuation<PhotoKitRequest.FinalResult, any Error>) -> Bool {
        let cancelled = storage.withLock { storage -> Bool in
            if storage.cancelled {
                storage.finished = true
                return true
            }
            storage.continuation = continuation
            return false
        }
        if cancelled {
            continuation.resume(throwing: CancellationError())
            return false
        }
        return true
    }

    func setRequestID(_ id: PHImageRequestID, manager: PHImageManager) {
        let cancelNow = storage.withLock { storage -> Bool in
            storage.requestID = id
            storage.manager = manager
            // Cancellation may have arrived before PhotoKit returned the request ID.
            return storage.cancelled
        }
        if cancelNow {
            manager.cancelImageRequest(id)
        }
    }

    func finish(_ result: Result<PhotoKitRequest.FinalResult, any Error>) {
        let continuation = storage.withLock { storage -> CheckedContinuation<PhotoKitRequest.FinalResult, any Error>? in
            guard !storage.finished else { return nil }
            storage.finished = true
            defer { storage.continuation = nil }
            return storage.continuation
        }
        continuation?.resume(with: result)
    }

    func cancel() {
        let (continuation, requestID, manager) = storage.withLock { storage in
            storage.cancelled = true
            guard !storage.finished else {
                return (nil as CheckedContinuation<PhotoKitRequest.FinalResult, any Error>?, nil as PHImageRequestID?, nil as PHImageManager?)
            }
            storage.finished = true
            defer { storage.continuation = nil }
            return (storage.continuation, storage.requestID, storage.manager)
        }
        if let requestID, let manager {
            manager.cancelImageRequest(requestID)
        }
        // PhotoKit may never call back after cancellation, so resume here.
        continuation?.resume(throwing: CancellationError())
    }
}
