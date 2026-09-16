import Foundation

/// Which recordings have a processing pipeline running right now, answered synchronously on
/// any thread.
///
/// The row statuses cannot answer that for the whole run. Between the upload landing and
/// transcription going `.queued` there is a thumbnail wait and a profile refresh during which
/// the row reads as idle, and every status write lands through a main-queue hop besides. The
/// on-device model warm-up needs a "busy" with no such gap: a compile that starts in it cannot
/// be cancelled, and the transcribe arriving seconds later has to contend with it.
///
/// Counted rather than a set: a retried upload re-enters the pipeline for the same recording,
/// and the first run finishing must not release the second one's claim.
final class PipelineClaims: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [UUID: Int] = [:]

    func claim(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        counts[id, default: 0] += 1
    }

    func release(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let count = counts[id] else { return }
        counts[id] = count > 1 ? count - 1 : nil
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return counts.isEmpty
    }
}
