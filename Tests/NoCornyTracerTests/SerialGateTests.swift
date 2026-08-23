import XCTest
@testable import NoCornyTracer

/// Counts how many pieces of work were ever inside the gate at the same time.
private actor Overlap {
    private var inside = 0
    private(set) var peak = 0
    private(set) var order: [Int] = []

    func enter(_ id: Int) { inside += 1; peak = max(peak, inside); order.append(id) }
    func leave() { inside -= 1 }
}

/// The gate exists because actor isolation does not do this job. An actor method that awaits
/// lets the next call in, so confining a shared CoreML pipeline to an actor protects the
/// dictionary around it and nothing else - which is what shipped: the diarizer's own comment
/// promised "two recordings finishing at once must not race its models" while the await in
/// its middle handed the second one the same manager.
final class SerialGateTests: XCTestCase {

    func testWorkNeverOverlaps() async {
        let gate = SerialGate()
        let overlap = Overlap()

        await withTaskGroup(of: Void.self) { group in
            for id in 0..<12 {
                group.addTask {
                    await gate.enqueue {
                        await overlap.enter(id)
                        // Suspends in the middle, which is the whole point: this is where a
                        // plain actor would let the next caller in.
                        try? await Task.sleep(nanoseconds: 2_000_000)
                        await overlap.leave()
                    }
                }
            }
        }

        let peak = await overlap.peak
        XCTAssertEqual(peak, 1, "two pieces of work were inside the gate at once")
        let count = await overlap.order.count
        XCTAssertEqual(count, 12, "the gate dropped work")
    }

    /// A failure belongs to whoever queued it, and must not wedge the queue behind it.
    func testAThrownErrorDoesNotWedgeTheQueue() async {
        let gate = SerialGate()
        struct Boom: Error {}

        async let first: Void = {
            do {
                _ = try await gate.enqueueThrowing { throw Boom() }
                XCTFail("the error was swallowed")
            } catch {
                XCTAssertTrue(error is Boom)
            }
        }()
        _ = await first

        let after = await gate.enqueue { 42 }
        XCTAssertEqual(after, 42, "the queue stayed wedged behind a failure")
    }

    /// Throwing and non-throwing work share one queue, so a mix of the two still serialises.
    func testBothEntryPointsShareTheSameQueue() async {
        let gate = SerialGate()
        let overlap = Overlap()

        await withTaskGroup(of: Void.self) { group in
            for id in 0..<6 {
                group.addTask {
                    if id.isMultiple(of: 2) {
                        await gate.enqueue {
                            await overlap.enter(id)
                            try? await Task.sleep(nanoseconds: 1_000_000)
                            await overlap.leave()
                        }
                    } else {
                        try? await gate.enqueueThrowing {
                            await overlap.enter(id)
                            try await Task.sleep(nanoseconds: 1_000_000)
                            await overlap.leave()
                        }
                    }
                }
            }
        }

        let peak = await overlap.peak
        XCTAssertEqual(peak, 1, "the two entry points ran past each other")
    }
}
