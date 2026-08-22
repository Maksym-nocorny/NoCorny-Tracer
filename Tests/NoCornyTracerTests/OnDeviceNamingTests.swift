import XCTest
@testable import NoCornyTracer

/// Tests the part that does not need Apple Intelligence: deciding whether what came back
/// is a title at all. Small models answer conversationally, and shipping "Here is a title
/// for your recording:" as the name of a recording is worse than falling back to the cloud.
final class OnDeviceNamingTests: XCTestCase {

    func testKeepsAPlainTitle() {
        XCTAssertEqual(OnDeviceNaming.clean("Webflow redesign walkthrough"), "Webflow redesign walkthrough")
    }

    func testStripsQuotesAndTrailingPunctuation() {
        XCTAssertEqual(OnDeviceNaming.clean("\"Figma spacing fixes\""), "Figma spacing fixes")
        XCTAssertEqual(OnDeviceNaming.clean("«Розбір макета»"), "Розбір макета")
        XCTAssertEqual(OnDeviceNaming.clean("Cobalt site review."), "Cobalt site review")
    }

    func testTakesOnlyTheFirstLine() {
        XCTAssertEqual(
            OnDeviceNaming.clean("Dropbox upload bug\n\nThis recording covers…"),
            "Dropbox upload bug"
        )
    }

    func testRejectsConversationalPackaging() {
        XCTAssertNil(OnDeviceNaming.clean("Here is a title for your recording:"))
        XCTAssertNil(OnDeviceNaming.clean("Sorry, I can't help with that."))
        XCTAssertNil(OnDeviceNaming.clean("Title: something"))
    }

    func testRejectsSomethingTooShortOrTooLong() {
        XCTAssertNil(OnDeviceNaming.clean("ok"))
        XCTAssertNil(OnDeviceNaming.clean(String(repeating: "word ", count: 40)))
    }

    func testRejectsEmpty() {
        XCTAssertNil(OnDeviceNaming.clean("   \n  "))
    }

    /// Not an assertion about this machine -- just makes the reason visible when the run
    /// happens somewhere the on-device path cannot be exercised.
    func testReportsWhyItIsUnavailable() {
        if OnDeviceNaming.isAvailable {
            XCTAssertNil(OnDeviceNaming.unavailableReason)
        } else {
            print("ℹ️ on-device naming unavailable: \(OnDeviceNaming.unavailableReason ?? "?")")
            XCTAssertNotNil(OnDeviceNaming.unavailableReason)
        }
    }
}
