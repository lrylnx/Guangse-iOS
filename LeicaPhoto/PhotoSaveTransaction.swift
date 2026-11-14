import Foundation

/// Two independently confirmed writes. Retrying a partial save passes nil for
/// the already-confirmed resource; cancellation never undoes a Photos success.
@MainActor
enum PhotoSaveTransaction {
    struct Outcome {
        var originalSaved = false
        var effectSaved = false
        var originalError: Error?
        var effectError: Error?
    }
    static func run(original: (() async throws -> Void)?,
                    effect: (() async throws -> Void)?) async -> Outcome {
        var outcome = Outcome()
        guard !Task.isCancelled else { return outcome }
        if let original {
            do { try await original(); outcome.originalSaved = true }
            catch is CancellationError { return outcome }
            catch { outcome.originalError = error }
        }
        guard !Task.isCancelled else { return outcome }
        if let effect {
            do { try await effect(); outcome.effectSaved = true }
            catch is CancellationError { }
            catch { outcome.effectError = error }
        }
        return outcome
    }
}
