import Foundation

/// Runs queued work one at a time, in the order it was queued.
///
/// An `actor` alone does not give this. Actor methods are reentrant: the moment one of them
/// awaits, another call gets in. That is exactly the wrong shape for guarding something like
/// a shared CoreML pipeline, where the whole body is awaits and the state being protected
/// lives inside the thing being awaited.
///
/// Chaining tasks does give it: each caller waits on the one queued before it, so the bodies
/// never overlap even though every one of them suspends.
actor SerialGate {
    private var tail: Task<Void, Never> = Task {}

    func enqueue<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        let previous = tail
        let mine = Task { () -> T in
            // Never throws, so a cancelled predecessor cannot wedge the queue behind it.
            await previous.value
            return await work()
        }
        tail = Task { _ = await mine.value }
        return await mine.value
    }

    /// Same queue, for work that can fail. A thrown error is the caller's, and never wedges
    /// whoever is queued behind it.
    func enqueueThrowing<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let mine = Task<T, Error> {
            await previous.value
            return try await work()
        }
        tail = Task { _ = try? await mine.value }
        return try await mine.value
    }
}
