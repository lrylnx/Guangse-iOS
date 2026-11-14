import Foundation

@main
struct SaveRetryCheck {
    @MainActor static func main() async {
        func check(_ value: Bool, _ text: String) { precondition(value, text); print("PASS \(text)") }
        let failure = NSError(domain: "InjectedPhotoLibraryFailure", code: 3300)
        var originals = 0, effects = 0
        let first = await PhotoSaveTransaction.run(original: { throw failure }, effect: { effects += 1 })
        check(!first.originalSaved && first.originalError != nil && first.effectSaved && effects == 1, "original failure does not prevent effect from saving")
        let retry = await PhotoSaveTransaction.run(original: { originals += 1 }, effect: nil)
        check(retry.originalSaved && originals == 1 && effects == 1, "retry original only cannot duplicate the confirmed effect")
        let second = await PhotoSaveTransaction.run(original: { originals += 1 }, effect: { throw failure })
        check(second.originalSaved && second.effectError != nil && !second.effectSaved, "effect failure preserves original success")
        let effectRetry = await PhotoSaveTransaction.run(original: nil, effect: { effects += 1 })
        check(effectRetry.effectSaved && originals == 2 && effects == 2, "retry effect only cannot duplicate the confirmed original")
        let bothFailed = await PhotoSaveTransaction.run(original: { throw failure }, effect: { throw failure })
        check(bothFailed.originalError != nil && bothFailed.effectError != nil, "both resource errors remain available for diagnostics")
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await PhotoSaveTransaction.run(original: { originals += 1 }, effect: { effects += 1 })
        }
        _ = await cancelled.value
        check(originals == 2 && effects == 2, "cancellation before save performs no writes")
        let interrupted = Task { @MainActor in
            await PhotoSaveTransaction.run(original: {
                originals += 1
                // A successful Photos transaction is still success when Stop
                // arrived while the asynchronous write was in flight.
                withUnsafeCurrentTask { $0?.cancel() }
            }, effect: { effects += 1 })
        }
        let interruptedOutcome = await interrupted.value
        check(interruptedOutcome.originalSaved && originals == 3 && effects == 2, "stop during original records confirmed success and skips effect")
        print("ALL PARTIAL SAVE / RETRY CHECKS PASSED")
    }
}
