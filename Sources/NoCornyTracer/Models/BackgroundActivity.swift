import Foundation

// What the command bar's activity pills (and the tray's "↑N") say, computed as pure
// functions of the state AppState already keeps. The UI phase of the redesign renders
// these; nothing here renders anything, which is what makes the mapping testable without
// a window.

/// The upload pill: how many videos are moving and how far along they are, averaged.
struct UploadPillState: Equatable {
    var count: Int
    var fraction: Double
}

/// The transcription pill. `fraction` is nil when nothing live has reported a number yet
/// (everything still queued, or an engine that cannot measure itself) - the pill shows an
/// indeterminate spinner rather than a bar frozen at zero.
struct TranscribePillState: Equatable {
    var count: Int
    var fraction: Double?
}

enum BackgroundActivity {

    /// nil when nothing is uploading - the pill disappears rather than showing "0".
    /// The fraction averages only the recordings whose byte counters have started moving;
    /// before any have, it is 0, which the pill draws as an empty bar about to fill.
    static func uploads(progress: [UUID: Double], recordings: [Recording]) -> UploadPillState? {
        let uploading = recordings.filter { $0.uploadStatus == .uploading }
        guard !uploading.isEmpty else { return nil }
        let fractions = uploading.compactMap { progress[$0.id] }
        let fraction = fractions.isEmpty ? 0.0 : fractions.reduce(0, +) / Double(fractions.count)
        return UploadPillState(count: uploading.count, fraction: fraction)
    }

    /// nil when nothing is queued or transcribing. The count includes queued work - it is
    /// owed, and hiding it would make three queued recordings look like idle time - while
    /// the fraction averages only live numbers, going nil when there are none.
    static func transcriptions(
        recordings: [Recording],
        activity: [UUID: TranscriptionProgress]
    ) -> TranscribePillState? {
        let active = recordings.filter(\.isTranscriptionActive)
        guard !active.isEmpty else { return nil }
        let fractions = active.compactMap { activity[$0.id]?.fraction }
        let fraction = fractions.isEmpty ? nil : fractions.reduce(0, +) / Double(fractions.count)
        return TranscribePillState(count: active.count, fraction: fraction)
    }

    /// Everything in flight, for the tray icon's "↑N". A recording that is uploading AND
    /// queued for transcription counts once per axis on purpose: the number answers "how
    /// many jobs finish before quitting is free", not "how many rows are busy".
    static func totalBackgroundCount(recordings: [Recording]) -> Int {
        let uploading = recordings.filter { $0.uploadStatus == .uploading }.count
        let transcribing = recordings.filter(\.isTranscriptionActive).count
        return uploading + transcribing
    }
}
