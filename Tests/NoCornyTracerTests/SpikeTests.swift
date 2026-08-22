import XCTest
@testable import NoCornyTracer

/// Phase-0 spike: proves a test target can link against the executable target
/// (which carries @main and an -sectcreate linker flag).
final class SpikeTests: XCTestCase {
    func testTargetLinks() {
        XCTAssertTrue(true)
    }
}
