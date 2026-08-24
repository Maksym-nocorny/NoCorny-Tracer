import XCTest
@testable import NoCornyTracer

/// A manual, environment-gated tool, not part of the suite: retitles one real recording
/// through the exact code path the app uses, against live Gemini, and pushes the result to
/// the site. Exists because the app has no "regenerate title" button, and the first field
/// failure of on-device naming left a Russian recording titled in English - the honest test
/// of the fix is the same transcript through the new path.
///
/// Run:  NCT_LIVE_RETITLE=<slug> NCT_LIVE_SRT=<path> swift test --filter LiveRetitle
final class LiveRetitleTests: XCTestCase {

    func testRetitleOneRealRecording() async throws {
        guard let slug = ProcessInfo.processInfo.environment["NCT_LIVE_RETITLE"],
              let srtPath = ProcessInfo.processInfo.environment["NCT_LIVE_SRT"] else {
            throw XCTSkip("set NCT_LIVE_RETITLE and NCT_LIVE_SRT to run this")
        }
        let srt = try String(contentsOfFile: srtPath, encoding: .utf8)
        let cues = SrtCodec.parseAndRepairSrt(srt)
        XCTAssertFalse(cues.isEmpty, "the SRT did not parse")

        let proxy = GeminiProxyClient(tokenProvider: { KeychainHelper.load(key: "TracerAPIToken") })
        XCTAssertTrue(proxy.isReady, "no Tracer token in the Keychain on this machine")
        let naming = NamingService(proxyClient: proxy)
        let transcript = naming.namingTranscriptText(cues)

        // The decision under test: Cyrillic must not go to the on-device model.
        XCTAssertFalse(OnDeviceNaming.canTitle(transcript: transcript),
                       "the gate would hand this to the on-device model again")

        let call = await naming.generateNameFromTranscript(transcript: transcript, frames: [], glossary: [])
        let title = try XCTUnwrap(call.name, "the cloud produced no title: \(call.errorCode ?? "?")")
        print("LIVE-RETITLE new title: \(title)")
        XCTAssertEqual(LanguageDetection.dominantScript(title), .cyrillic,
                       "the title came back in the wrong language again: \(title)")
        XCTAssertNotEqual(call.model, "apple-on-device", "the gate did not gate")

        let ok = await TracerAPIClient().updateVideo(slug: slug, title: title)
        XCTAssertTrue(ok, "the site did not accept the new title")
    }
}
