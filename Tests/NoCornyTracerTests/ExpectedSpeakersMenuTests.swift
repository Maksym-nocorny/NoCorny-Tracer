import XCTest
@testable import NoCornyTracer

/// The compact speaker menus of the redesign (drawer "People in new recordings" row
/// and the Gallery row's context submenu) offer Auto / 2 / 3 / 4 — but the enum has
/// seven cases and old stored values must stay representable. These pin the mapping.
final class ExpectedSpeakersMenuTests: XCTestCase {

    func testQuickPickOfferIsAutoTwoThreeFour() {
        XCTAssertEqual(ExpectedSpeakers.quickPickCases, [.auto, .two, .three, .four])
    }

    func testShortNamesCoverEveryCase() {
        let expected: [ExpectedSpeakers: String] = [
            .auto: "Auto", .justMe: "Just me", .two: "2", .three: "3",
            .four: "4", .five: "5", .manyMore: "6+"
        ]
        for speakers in ExpectedSpeakers.allCases {
            XCTAssertEqual(speakers.shortName, expected[speakers])
        }
    }

    func testCurrentValueInsideTheOfferChangesNothing() {
        XCTAssertEqual(
            ExpectedSpeakers.quickPickChoices(including: .three),
            [.auto, .two, .three, .four]
        )
    }

    func testCurrentValueOutsideTheOfferIsSplicedInOrder() {
        // A value picked in the old full-list UI (or per recording) must show as
        // selected instead of leaving the menu with no tick anywhere.
        XCTAssertEqual(
            ExpectedSpeakers.quickPickChoices(including: .justMe),
            [.auto, .justMe, .two, .three, .four]
        )
        XCTAssertEqual(
            ExpectedSpeakers.quickPickChoices(including: .manyMore),
            [.auto, .two, .three, .four, .manyMore]
        )
    }
}
