import AppKit
import UserNotifications

/// System (Notification Center) notifications — round 7. Two clients:
///
/// 1. **Upload finished** ("Uploaded / Link copied — click to open"): replaces the
///    old in-app "Uploaded — link copied" toast. A toast over the desk is easy to
///    miss and impossible to act on once gone; the system notification survives in
///    Notification Center and its click opens the recording's tracer page.
/// 2. **Microphone stopped**: a DUPLICATE of the critical in-app toast, not a
///    replacement — the toast stays for whoever is looking at this screen, the
///    notification reaches the user in another Space / on another display.
///
/// Authorization is requested LAZILY on the first send (never at launch — an app
/// asking for notification rights before it has ever done anything reads as spam),
/// via the standard one-time system prompt. If the user denies it, the uploaded
/// notice FALLS BACK to the old toast (passed in by the caller), so the "your link
/// is ready" moment is never silently lost; the mic case needs no fallback since
/// its toast always fires anyway.
///
/// Unbundled runs (swift run / test binaries, where `Bundle.main.bundleIdentifier`
/// is nil) cannot use UNUserNotificationCenter at all — `current()` throws an
/// Objective-C exception with no bundle proxy. `centerAvailable` gates every touch
/// of the framework, and such runs simply use the fallback path. The packaged .app
/// (com.nocorny.tracer) is the real target.
final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {

    static let shared = AppNotifications()

    // MARK: - Pure decisions (covered by AppNotificationsLogicTests)

    /// What a notification says and carries. Pure so the wording and the click
    /// payload are testable without UNUserNotificationCenter (which does not
    /// even exist for the test runner — see the class note).
    struct Payload: Equatable {
        var title: String
        var body: String
        /// Lands in userInfo[Self.urlKey]; the click opens it.
        var urlString: String?
    }

    static let urlKey = "url"

    /// The uploaded notice. `pageURL` is the recording's share URL — the tracer
    /// page when the slug resolved, else the raw Dropbox link (same priority as
    /// the clipboard copy, so the click and the paste always agree).
    static func uploadedPayload(pageURL: URL) -> Payload {
        Payload(
            title: "Uploaded",
            body: "Link copied — click to open",
            urlString: pageURL.absoluteString
        )
    }

    /// The mic-loss duplicate: same sentence as the critical toast, so the user
    /// who sees both reads ONE event, not two different problems.
    static func microphoneStoppedPayload(message: String) -> Payload {
        Payload(title: "Microphone stopped", body: message, urlString: nil)
    }

    /// Whether a notification response click opens anything: the URL out of
    /// userInfo, nil for garbage or a missing key.
    static func clickURL(userInfo: [AnyHashable: Any]) -> URL? {
        guard let string = userInfo[urlKey] as? String else { return nil }
        return URL(string: string)
    }

    /// Where a notice goes once the authorization answer is in. Pure — the
    /// fallback rule in one testable place: no center (unbundled run) or no
    /// grant (denied prompt) → the caller's fallback presenter.
    enum Delivery: Equatable {
        case systemNotification
        case fallback
    }

    static func delivery(centerAvailable: Bool, granted: Bool) -> Delivery {
        (centerAvailable && granted) ? .systemNotification : .fallback
    }

    // MARK: - Posting

    /// Post `payload` as a system notification; `fallback` runs (on main) when
    /// notifications cannot be delivered — unbundled run, or authorization
    /// denied. Pass nil for events that already have their own in-app surface
    /// (the mic toast): then a denial simply means no duplicate.
    func post(_ payload: Payload, fallback: (() -> Void)? = nil) {
        // UNUserNotificationCenter.current() requires a real bundle — see the
        // class note. Unbundled runs go straight to the fallback.
        guard Self.centerAvailable else {
            runOnMain { fallback?() }
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Lazy authorization: the FIRST send shows the system prompt; every
        // later call resolves instantly with the standing verdict.
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            guard let self else { return }
            switch Self.delivery(centerAvailable: true, granted: granted) {
            case .systemNotification:
                self.deliver(payload, via: center)
            case .fallback:
                self.runOnMain { fallback?() }
            }
        }
    }

    private func deliver(_ payload: Payload, via center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.sound = .default
        if let urlString = payload.urlString {
            content.userInfo = [Self.urlKey: urlString]
        }
        // Unique identifier per post: two uploads in a row are two notices.
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                LogManager.shared.log(
                    "🔔 Notification failed to post: \(error.localizedDescription)",
                    type: .error
                )
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show banners even while the app is "frontmost" — this panel app is
    /// technically active whenever a drawer has focus, and suppressing the
    /// banner then would hide exactly the uploads finished mid-use.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// The click: open the URL the notification carries (the recording's page).
    /// A notification without one (mic loss) just dismisses.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let url = Self.clickURL(userInfo: response.notification.request.content.userInfo) {
            runOnMain { NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }

    // MARK: - Plumbing

    private static var centerAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    /// Completion handlers arrive on arbitrary queues; the fallbacks build
    /// panels and the click opens a browser — both belong on main.
    private func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
