import Foundation
import Sparkle

/// Keeps Sparkle out of the way while a recording is running.
///
/// Two separate problems, both of which only happen to someone mid-meeting:
///
/// The update window is an ordinary window, so a scheduled check that fires during a capture
/// puts Sparkle's own dialog into the screen recording. And "Install and Relaunch" quits the
/// app, which ends the recording - the take is saved, but the rest of the meeting is not, and
/// nothing in that dialog suggests it is about to happen.
///
/// So checks are declined while recording, and Sparkle is asked to come back later. The
/// update is not skipped or forgotten: Sparkle keeps its own schedule and asks again.
final class UpdateScheduler: NSObject, SPUUpdaterDelegate {

    /// Nil until AppState exists. Read at the moment Sparkle asks rather than captured, so a
    /// recording that starts after launch still counts.
    var isRecording: () -> Bool = { false }

    func updater(_ updater: SPUUpdater, mayPerform check: SPUUpdateCheck) throws {
        // A check the user asked for is theirs to make - they can see what is on screen.
        guard check == .updatesInBackground, isRecording() else { return }
        LogManager.shared.log("⬆️ Updater: declined a background check - a recording is running")
        throw NSError(
            domain: "com.nocorny.tracer.updater",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "A recording is in progress"]
        )
    }
}
