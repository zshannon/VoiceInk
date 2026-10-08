import Foundation

/// Lives for one invocation, including provider work and pending delivery.
/// Starting a new invocation never clears cancellation of the previous one.
@MainActor
final class RecordingCancellationState {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }

    func runStartupAttempt(_ start: () async throws -> Void) async throws {
        guard !isCancelled, !Task.isCancelled else { throw CancellationError() }
        try await start()
        guard !isCancelled, !Task.isCancelled else { throw CancellationError() }
    }
}
