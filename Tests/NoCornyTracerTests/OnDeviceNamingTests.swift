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

/// The on-device model's answer to a Cyrillic transcript is worse than a refusal: an English
/// title, with the product's own name mistranslated. Found on the first real Cyrillic
/// recording after release - the transcript was flawless and the title called a screen
/// recorder a gym trainer.
final class OnDeviceNamingLanguageGateTests: XCTestCase {

    func testACyrillicTranscriptIsSentToTheCloud() {
        let transcript = "записываем экран того как я работаю сейчас с нокорни трейсером мы продумываем новый дизайн"
        XCTAssertFalse(OnDeviceNaming.canTitle(transcript: transcript),
                       "the on-device model would answer this in English")
    }

    func testAUkrainianTranscriptIsSentToTheCloud() {
        XCTAssertFalse(OnDeviceNaming.canTitle(transcript: "сьогодні ми записуємо екран і проговорюємо новий дизайн застосунку"))
    }

    func testAnEnglishTranscriptStaysOnDevice() {
        XCTAssertTrue(OnDeviceNaming.canTitle(transcript: "today we are walking through the new design concepts for the tracer app"))
    }

    /// Latin words inside Cyrillic speech are normal - Figma, API, product names - and must
    /// not flip the decision: the dominant script decides, not the presence of either.
    func testLatinWordsInsideCyrillicSpeechDoNotFlipTheGate() {
        XCTAssertFalse(OnDeviceNaming.canTitle(transcript: "ми зараз сидимо в Claude Code і працюємо з NoCorny Tracer над дизайном застосунку"))
    }
}
