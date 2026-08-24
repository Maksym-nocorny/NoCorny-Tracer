import XCTest
@testable import NoCornyTracer

/// The mapping from app state to the command bar's activity pills. Pure functions, and the
/// edges are the point: a pill that shows "0" instead of disappearing, an average poisoned
/// by a recording whose counter has not started, a determinate bar frozen at zero when
/// nothing has reported a number yet.
final class BackgroundActivityMappingTests: XCTestCase {

    private func recording(
        _ path: String,
        upload: UploadStatus = .uploaded,
        transcription: TranscriptionStatus? = nil
    ) -> Recording {
        var r = Recording(fileURL: URL(fileURLWithPath: path), uploadStatus: upload)
        r.transcriptionStatus = transcription
        return r
    }

    // MARK: - Nothing happening

    func testNothingActiveMeansNoPills() {
        let settled = [
            recording("/tmp/pill-done.mp4", upload: .uploaded, transcription: .done),
            recording("/tmp/pill-failed.mp4", upload: .failed, transcription: .failed),
            recording("/tmp/pill-fresh.mp4", upload: .notUploaded),
        ]
        XCTAssertNil(BackgroundActivity.uploads(progress: [:], recordings: settled))
        XCTAssertNil(BackgroundActivity.transcriptions(recordings: settled, activity: [:]))
        XCTAssertEqual(BackgroundActivity.totalBackgroundCount(recordings: settled), 0)
    }

    // MARK: - Uploads

    func testTwoUploadsAverageTheirBars() {
        let first = recording("/tmp/pill-up-a.mp4", upload: .uploading)
        let second = recording("/tmp/pill-up-b.mp4", upload: .uploading)
        let bystander = recording("/tmp/pill-up-c.mp4", upload: .uploaded)

        let pill = BackgroundActivity.uploads(
            progress: [first.id: 0.2, second.id: 0.6, bystander.id: 0.9],
            recordings: [first, second, bystander]
        )

        XCTAssertEqual(pill?.count, 2)
        XCTAssertEqual(pill?.fraction ?? -1, 0.4, accuracy: 0.0001,
                       "a stale counter from a finished upload poisoned the average")
    }

    /// The moments before URLSession's byte counter starts: the upload is real and must
    /// count, and the bar starts empty rather than dividing by nothing.
    func testAnUploadWithoutACounterYetStillCounts() {
        let starting = recording("/tmp/pill-up-early.mp4", upload: .uploading)
        let pill = BackgroundActivity.uploads(progress: [:], recordings: [starting])
        XCTAssertEqual(pill?.count, 1)
        XCTAssertEqual(pill?.fraction, 0)
    }

    // MARK: - Transcriptions

    func testQueuedAndTranscribingBothCount() {
        let waiting = recording("/tmp/pill-tr-queued.mp4", transcription: .queued)
        let working = recording("/tmp/pill-tr-live.mp4", transcription: .transcribing)
        let settled = recording("/tmp/pill-tr-done.mp4", transcription: .done)

        let pill = BackgroundActivity.transcriptions(
            recordings: [waiting, working, settled],
            activity: [working.id: TranscriptionProgress(completedChunks: 1, totalChunks: 2, fraction: 0.5)]
        )

        XCTAssertEqual(pill?.count, 2, "queued work is owed, and hiding it reads as idle time")
        XCTAssertEqual(pill?.fraction ?? -1, 0.5, accuracy: 0.0001,
                       "the queued recording's missing number dragged the average down")
    }

    /// No live number yet - everything queued, or an engine that cannot measure itself.
    /// nil is the signal for an indeterminate spinner; 0 would draw a bar frozen at empty.
    func testNoLiveNumbersMeansIndeterminate() {
        let waiting = recording("/tmp/pill-tr-only-queued.mp4", transcription: .queued)
        let pill = BackgroundActivity.transcriptions(recordings: [waiting], activity: [:])
        XCTAssertEqual(pill?.count, 1)
        XCTAssertNil(pill?.fraction)
    }

    // MARK: - The tray's one number

    /// The number answers "how many jobs finish before quitting is free", so one recording
    /// busy on both axes counts once per axis.
    func testTotalBackgroundCountSumsBothAxes() {
        let doubleBusy = recording("/tmp/pill-total-both.mp4", upload: .uploading, transcription: .queued)
        let transcribing = recording("/tmp/pill-total-tr.mp4", transcription: .transcribing)
        let settled = recording("/tmp/pill-total-done.mp4", transcription: .done)

        XCTAssertEqual(
            BackgroundActivity.totalBackgroundCount(recordings: [doubleBusy, transcribing, settled]),
            3
        )
    }
}
