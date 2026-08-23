import Foundation

/// What quitting should do about a recording that is still being dealt with.
///
/// Reading `isRecording` alone was wrong in both directions, and each direction cost a whole
/// recording:
///
/// - A stop already in flight still reads as recording, so the quit handler started a second
///   one, got nil back because the first was already running, and read that as "nothing to
///   wait for" - terminating the process on top of a file that had not been finalised.
/// - A take being mixed reads as not recording at all, so quitting killed the export.
///
/// Pulled out of the delegate because a delegate method cannot be held by a test, and this is
/// the piece where getting it wrong is invisible until someone loses a meeting.
enum QuitDecision {
    /// Whether anything is still in flight that quitting would damage.
    static func isBusy(isRecording: Bool, isStopping: Bool, isFinishing: Bool) -> Bool {
        isRecording || isStopping || isFinishing
    }

    /// Whether the quit handler should be the one to stop the recording. Only when nobody
    /// else already is: a stop in flight finalises the file and saves the row on its own.
    static func shouldStartAStop(isRecording: Bool, isStopping: Bool) -> Bool {
        isRecording && !isStopping
    }
}
