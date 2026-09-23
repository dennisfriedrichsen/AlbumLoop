import AlbumLoopCore
import SwiftUI

/// Development diagnostics drawn over the slideshow. Shows counts and timings
/// only; never image content or raw asset identifiers.
struct DiagnosticsOverlay: View {
    let diagnostics: PlaybackDiagnostics
    let eligibleAlbums: Int
    let phase: SlideshowController.Phase
    let isNetworkAvailable: Bool

    var body: some View {
        let buffer = diagnostics.buffer
        VStack(alignment: .leading, spacing: 4) {
            Text("Session \(diagnostics.sessionID) · cycle \(diagnostics.cycle) · \(phaseText)")
            Text("Position \(diagnostics.position) / \(diagnostics.total) · eligible albums \(eligibleAlbums)")
            Text("Displayed \(diagnostics.displayedThisCycle) · skipped \(diagnostics.skippedThisCycle) · removed \(diagnostics.removedThisCycle)")
            Text("Buffered \(buffer.ready) · loading \(buffer.loading) · pending \(buffer.pending) · failed \(buffer.failed)")
            Text("Memory \(megabytes(buffer.decodedBytes)) / \(megabytes(buffer.byteBudget)) · retries \(buffer.retries) · stale \(buffer.staleCallbacks)")
            Text("Requests ok \(buffer.completedRequests) · failed \(buffer.failedRequests) · network \(isNetworkAvailable ? "up" : "DOWN")")
            Divider().overlay(.white.opacity(0.3))
            ForEach(diagnostics.recentRequests.suffix(6).reversed()) { record in
                Text("\(record.assetToken) #\(record.attempt) \(seconds(record.duration)) \(outcomeText(record.outcome))")
                    .lineLimit(1)
            }
        }
        .font(.system(size: 20, design: .monospaced))
        .foregroundStyle(.white)
        .padding(20)
        .frame(width: 900, alignment: .leading)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
    }

    private var phaseText: String {
        switch phase {
        case .idle: "idle"
        case .loading: "loading"
        case .showing: "showing"
        case .stalled: "stalled"
        case .finished: "finished"
        case .failed: "failed"
        }
    }

    private func megabytes(_ bytes: Int) -> String {
        "\(bytes / 1_000_000) MB"
    }

    private func seconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.2fs", value)
    }

    private func outcomeText(_ outcome: RequestRecord.Outcome) -> String {
        switch outcome {
        case .succeeded: "ok"
        case .cancelled: "cancelled"
        case .failed(let failure): "✗ \(failure.kind.rawValue)"
        }
    }
}
