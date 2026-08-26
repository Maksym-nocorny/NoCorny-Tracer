import XCTest
@testable import NoCornyTracer

/// The pure decisions behind the system notifications (round 7): payload wording,
/// the click payload round-trip, and the fallback rule. Pure on purpose — the
/// test runner has no bundle, so UNUserNotificationCenter cannot even be
/// constructed here (AppNotifications gates every touch of it for that reason).
final class AppNotificationsLogicTests: XCTestCase {

    // MARK: Payloads

    func testUploadedPayloadCarriesThePage() throws {
        let url = try XCTUnwrap(URL(string: "https://tracer.nocorny.com/v/abc123"))
        XCTAssertEqual(
            AppNotifications.uploadedPayload(pageURL: url),
            AppNotifications.Payload(
                title: "Uploaded",
                body: "Link copied — click to open",
                urlString: "https://tracer.nocorny.com/v/abc123"
            )
        )
    }

    /// The notification and the critical toast must read as ONE event — the
    /// payload takes the toast's sentence verbatim and carries no URL (there is
    /// nothing to open; the fix happens in the app).
    func testMicrophoneStoppedPayloadEchoesTheToast() {
        let payload = AppNotifications.microphoneStoppedPayload(message: AppState.micStoppedMessage)
        XCTAssertEqual(payload.title, "Microphone stopped")
        XCTAssertEqual(payload.body, AppState.micStoppedMessage)
        XCTAssertNil(payload.urlString)
    }

    // MARK: Click payload round-trip

    func testClickURLReadsWhatThePayloadWrote() throws {
        let url = try XCTUnwrap(URL(string: "https://tracer.nocorny.com/v/abc123"))
        let payload = AppNotifications.uploadedPayload(pageURL: url)
        let userInfo: [AnyHashable: Any] = [AppNotifications.urlKey: payload.urlString!]
        XCTAssertEqual(AppNotifications.clickURL(userInfo: userInfo), url)
    }

    func testClickURLRejectsMissingOrGarbageEntries() {
        XCTAssertNil(AppNotifications.clickURL(userInfo: [:]))
        XCTAssertNil(AppNotifications.clickURL(userInfo: ["other": "https://x.y"]))
        XCTAssertNil(AppNotifications.clickURL(userInfo: [AppNotifications.urlKey: 42]))
    }

    // MARK: Fallback rule

    func testGrantedAndBundledGoesToTheSystem() {
        XCTAssertEqual(
            AppNotifications.delivery(centerAvailable: true, granted: true),
            .systemNotification
        )
    }

    /// A denied prompt must not lose the "your link is ready" moment — the old
    /// toast takes over.
    func testDeniedFallsBackToTheToast() {
        XCTAssertEqual(
            AppNotifications.delivery(centerAvailable: true, granted: false),
            .fallback
        )
    }

    /// Unbundled runs (swift run, tests) have no notification center at all —
    /// the grant flag cannot rescue them.
    func testNoBundleFallsBackRegardlessOfGrant() {
        XCTAssertEqual(
            AppNotifications.delivery(centerAvailable: false, granted: true),
            .fallback
        )
        XCTAssertEqual(
            AppNotifications.delivery(centerAvailable: false, granted: false),
            .fallback
        )
    }
}
