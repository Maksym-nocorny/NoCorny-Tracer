import AVFoundation

/// What flipping a capture toggle ON (mic / camera in the command bar) should do,
/// given the device's TCC authorization status. Pure so the mapping is testable
/// without touching AVFoundation's real permission state.
///
/// Exists because of the 25.08 demo bug: the camera toggle fed `isEnabled`
/// straight into the capture session, whose permission check silently returned
/// on `.denied` — the toggle stayed ON over a dead camera, and nobody asked the
/// system for access or told the user why nothing happened.
enum CaptureToggleDecision: Equatable {
    /// Access is granted — enable the capture right away.
    case enable
    /// Never asked — show the one-tap system prompt, then enable on grant.
    case requestAccess
    /// Denied or restricted — the toggle stays OFF; tell the user and point at
    /// System Settings (the prompt will not appear again).
    case deniedFeedback

    static func forTurningOn(status: AVAuthorizationStatus) -> CaptureToggleDecision {
        switch status {
        case .authorized:
            return .enable
        case .notDetermined:
            return .requestAccess
        case .denied, .restricted:
            return .deniedFeedback
        @unknown default:
            return .deniedFeedback
        }
    }
}
