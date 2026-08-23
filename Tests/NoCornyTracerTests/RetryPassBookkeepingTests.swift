import XCTest
@testable import NoCornyTracer

/// A retry that reuses a cached transcript is the awkward case: it must not redo the
/// expensive work, and it must not pretend it did.
final class RetryPassBookkeepingTests: XCTestCase {

    // MARK: - Which engine gets the credit

    func testAPassThatTranscribedNothingLeavesTheEarlierAnswerAlone() {
        XCTAssertEqual(
            AppState.engineToRecord(producedNow: nil, existing: "whisperkit-large-v3-turbo"),
            "whisperkit-large-v3-turbo",
            "a retry relabelled work done on this Mac as something else"
        )
    }

    func testAPassThatDidTranscribeIsTheOneCredited() {
        XCTAssertEqual(
            AppState.engineToRecord(producedNow: "gemini-2.5-flash", existing: "whisperkit-large-v3-turbo"),
            "gemini-2.5-flash"
        )
    }

    func testNothingKnownStaysNothingKnown() {
        XCTAssertNil(AppState.engineToRecord(producedNow: nil, existing: nil))
    }

    // MARK: - Whether there is anything to name

    private func service() -> AINamingService {
        let proxy = GeminiProxyClient(tokenProvider: { nil })
        return AINamingService(engines: [], preferring: .cloudGemini,
                               namingService: NamingService(proxyClient: proxy))
    }

    private let srt = """
    1
    00:00:00,000 --> 00:00:02,000
    the part where we agreed on the deadline

    """

    func testATranscriptWithWordsCanBeNamed() {
        let text = service().nameableText(from: srt, canName: true)
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains("deadline") == true, "the transcript reached naming stripped of its words")
    }

    /// The half that can swallow everything quietly: if this starts saying no, no recording
    /// gets a title from any engine except Gemini's single-call path, and nothing fails.
    func testNobodyToNameMeansNoCall() {
        XCTAssertNil(service().nameableText(from: srt, canName: false))
    }

    func testAnEmptyTranscriptIsNotWorthACall() {
        XCTAssertNil(service().nameableText(from: "", canName: true))
        XCTAssertNil(service().nameableText(from: "\n\n\n", canName: true))
    }
}
