import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox

/// Writes video and audio sample buffers to a compressed MP4 file using AVAssetWriter
final class VideoWriter {
    // MARK: - Configuration
    private let outputURL: URL
    private let videoWidth: Int
    private let videoHeight: Int
    private let videoBitRate: Int
    private let fps: Int

    // MARK: - AVAssetWriter
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?

    // MARK: - Timing
    /// False during the pre-roll warm-up, true once the recording timeline begins (see `arm()`).
    /// Buffers received while disarmed are discarded — this is the warm-up window that lets the
    /// start sound finish AND the mic's voice-processing unit fully spin up before recording, so
    /// the first words spoken aren't clipped.
    private var armed = false
    private var sessionStarted = false
    private var sessionStartTime: CMTime = .zero
    private var isWriting = false

    // MARK: - Pause timeline
    //
    // A pause removes time by subtracting `ptsOffset` from every source timestamp, on
    // BOTH tracks, so audio and video inside one segment keep exactly their capture sync.
    //
    // The offset must be decided in OUTPUT time, against what was actually written on
    // each track. The two sources run on different lags: a screen frame arrives a few ms
    // after its stamp, while a mic buffer is stamped at its FIRST sample and arrives a
    // whole buffer (about 105 ms) later. The old code measured the gap from one shared
    // "last source PTS". When a mic buffer was the last append before the pause and a
    // video frame the first after the resume, the gap included the mic lag, too much time
    // was cut, and the first resumed frame was stamped about 40 ms BEFORE the last written
    // one. The H.264 writer accepts that append and then dies with -11800 / -16364, which
    // leaves a file with no moov (incident 2026-10-09).

    private var ptsOffset: CMTime = .zero
    private var isPaused = false
    /// Raised by resume(). The first buffer of EITHER track that arrives afterwards places
    /// the new segment (see `placeResumedSegment`) and lowers it.
    private var needsResumeAdjustment = false
    /// Earliest output time the current segment may use: strictly after the last written
    /// sample of both tracks at the moment of the last resume. Invalid before any resume.
    private var segmentStart: CMTime = .invalid
    private var resumeCount = 0

    /// Last timestamps actually accepted by the writer, in OUTPUT (restamped) time.
    private var lastVideoOutPTS: CMTime = .invalid
    private var lastAudioOutPTS: CMTime = .invalid
    private var lastAudioOutEnd: CMTime = .invalid
    /// End of the last system-audio buffer handed to the sidecar, on the same output
    /// timeline. The sidecar drops any buffer that does not move past its last one, so a
    /// resumed segment must also start after this, not only after the two MP4 tracks.
    private var lastSystemAudioOutEnd: CMTime = .invalid
    /// Buffers whose restamped time would not move their own track forward. Expected at
    /// a resume seam (a mic buffer captured mostly during the pause), never elsewhere.
    private var restampDrops = 0
    private var appendRejectionLogged = false

    /// Slack for CMTime rounding when the offset mixes timescales (1e9 for the screen,
    /// 48000 for the mic): the buffer that places a segment must not be dropped for
    /// landing a few ns before the start it defined.
    private static let seamTolerance = CMTime(value: 1, timescale: 1000)

    /// Fired once (on the writing queue) when an append discovers the writer died
    /// mid-recording. CoreMedia's periodic fragment flush can fail spontaneously
    /// (seen in the wild as MovieHeaderMaker err -16341), flipping the writer to
    /// .failed — after which every buffer is silently dropped by the append guards.
    /// Set by RecordingManager before capture callbacks are attached.
    var onFailure: ((Error?) -> Void)?
    private var failureReported = false

    /// Under system-wide GPU load (kernel IOSurface storms) a realtime source can
    /// emit a buffer with a non-increasing timestamp. append() accepts it, but the
    /// writer's background fragment flush then fails on it and kills the whole
    /// writer — so track per-input PTS and drop such buffers at the door.
    private var lastVideoPTS: CMTime = .invalid
    private var lastAudioPTS: CMTime = .invalid
    private var outOfOrderDrops = 0


    // MARK: - Thread Safety
    private let writingQueue = DispatchQueue(label: "com.nocorny.tracer.videowriter", qos: .userInitiated)

    init(
        outputURL: URL,
        videoWidth: Int = 1920,
        videoHeight: Int = 1080,
        videoBitRate: Int = 6_000_000,
        fps: Int = 30
    ) {
        self.outputURL = outputURL
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.videoBitRate = videoBitRate
        self.fps = fps
    }

    // MARK: - Setup

    func startWriting() throws {
        // Remove existing file if needed
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        // DO NOT set writer.movieFragmentInterval here.
        //
        // It was previously set to 5s for crash-safety (so a crash/power-loss left a
        // playable file). But that periodic fragment flush is exactly what was killing
        // live recordings: every 5s CoreMedia's MovieHeaderMaker writes a moof fragment
        // on a background thread, and under system load / kernel IOSurface storms that
        // flush fails with OSStatus -16341, flipping the whole writer to .failed —
        // after which every frame is silently dropped. Seen repeatedly in the wild
        // (four deaths in a single 2026-07-15 session), each surfacing at a 5s
        // fragment boundary; the encoded frames themselves were always fine (the
        // salvaged partials decoded cleanly), so the failure is the flush, not the
        // encode. Removing the periodic flush removes the failure.
        //
        // Crash-safety is instead covered by finalizing the recording on quit
        // (applicationShouldTerminate → stopRecording → finishWriting). The only case
        // left unprotected is a hard crash / SIGKILL / power loss mid-recording, which
        // is rare — a far better trade than recordings dying mid-take every session.

        // Video input settings — H.264 at 1080p
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoWidth,
            AVVideoHeightKey: videoHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitRate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ]

        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true

        if writer.canAdd(vInput) {
            writer.add(vInput)
        }

        // Audio input settings — AAC at 48kHz mono, 128 kbps
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ]

        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        aInput.expectsMediaDataInRealTime = true

        if writer.canAdd(aInput) {
            writer.add(aInput)
        }

        self.assetWriter = writer
        self.videoInput = vInput
        self.audioInput = aInput
        self.armed = false
        self.sessionStarted = false
        self.isWriting = true

        // startWriting() returns false (and sets writer.status = .failed) when the
        // file can't be created — disk full, permission/sandbox problem, bad dir.
        // Ignoring it used to let the whole session record into a dead writer and
        // be lost silently at stop. Surface it as a throw instead.
        guard writer.startWriting() else {
            self.isWriting = false
            throw writer.error ?? VideoWriterError.failedToStart
        }
    }
    
    func pause() {
        writingQueue.async {
            guard !self.isPaused else { return }
            self.isPaused = true
            LogManager.shared.log("⏸ Writer: paused - last video out \(Self.format(self.lastVideoOutPTS)), last audio out end \(Self.format(self.lastAudioOutEnd)), last system audio out end \(Self.format(self.lastSystemAudioOutEnd)), offset \(Self.format(self.ptsOffset))")
        }
    }

    func resume() {
        writingQueue.async {
            guard self.isPaused else { return }
            self.isPaused = false
            self.resumeCount += 1
            self.needsResumeAdjustment = true
        }
    }

    /// Places the segment that follows a resume. Runs on writingQueue for the first buffer
    /// of either track that arrives after resume(), before that buffer is restamped.
    ///
    /// The new segment starts strictly after the last written sample of BOTH tracks: one
    /// frame interval after the last video frame, and no earlier than the end of the last
    /// mic buffer. It also starts no earlier than the end of the last system-audio buffer
    /// given to the sidecar: on a static screen with the mic off, the last frame can be
    /// seconds older than the pause while system audio kept flowing, and a start placed
    /// only after that frame would map post-resume system audio behind what the sidecar
    /// already holds (it would drop all of it until it caught up). The offset is chosen so this first buffer lands exactly there, whatever
    /// its track. Everything else in the segment shares that offset, so it keeps its sync
    /// with the first buffer; a buffer that would still land before the start (captured
    /// during the pause, or a mic buffer straddling the resume behind an earlier frame) is
    /// dropped by the per-track guard in the append paths.
    private func placeResumedSegment(firstSourcePTS: CMTime, track: String) {
        needsResumeAdjustment = false
        var start = CMTime.invalid
        if lastVideoOutPTS.isValid {
            start = lastVideoOutPTS + CMTime(value: 1, timescale: CMTimeScale(fps))
        }
        if lastAudioOutEnd.isValid {
            start = start.isValid ? CMTimeMaximum(start, lastAudioOutEnd) : lastAudioOutEnd
        }
        if lastSystemAudioOutEnd.isValid {
            start = start.isValid ? CMTimeMaximum(start, lastSystemAudioOutEnd) : lastSystemAudioOutEnd
        }
        // Nothing written yet (paused before the first frame): the session anchor places it.
        guard start.isValid else { return }

        let previousOffset = ptsOffset
        segmentStart = start
        ptsOffset = firstSourcePTS - start
        LogManager.shared.log("▶️ Writer: resumed #\(resumeCount) - first buffer \(track) src \(Self.format(firstSourcePTS)), segment starts at out \(Self.format(start)), removed \(Self.format(ptsOffset - previousOffset)), offset now \(Self.format(ptsOffset))")
    }


    // MARK: - Appending Buffers

    /// Begins the recording timeline. Buffers received before this — the pre-roll warm-up that
    /// lets the start sound finish and the microphone's voice-processing unit fully spin up — are
    /// discarded, so the recording starts cleanly with the mic already capturing (no clipped first
    /// words). The first video frame after arming anchors the session; audio is kept from there.
    func arm() {
        writingQueue.async { self.armed = true }
    }

    /// Whether the next video buffer would actually be written rather than dropped.
    ///
    /// `appendVideoBuffer` drops silently when the input is not ready - correct for a live
    /// capture, where waiting would stall the stream. A headless test driving this writer
    /// has no stream to stall and needs to know its frames landed, or it ends up asserting
    /// on an empty file that took a different path entirely.
    var isReadyForVideo: Bool {
        writingQueue.sync { isWriting && armed && (videoInput?.isReadyForMoreMediaData ?? false) }
    }

    /// The audio twin of `isReadyForVideo`, for the same reason.
    var isReadyForAudio: Bool {
        writingQueue.sync { isWriting && armed && (audioInput?.isReadyForMoreMediaData ?? false) }
    }

    func appendVideoBuffer(_ sampleBuffer: CMSampleBuffer) {
        writingQueue.sync {
            // Pause gating lives here (on writingQueue) instead of being read from
            // the capture thread off `RecordingManager.isPaused` — that was an
            // unsynchronized cross-thread Bool read (a data race).
            guard isWriting, !isPaused, armed,
                  let writer = assetWriter else { return }
            guard writer.status == .writing else {
                reportFailureIfNeeded(writer)
                return
            }
            guard let videoInput = videoInput,
                  videoInput.isReadyForMoreMediaData else { return }

            let originalPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            if lastVideoPTS.isValid, originalPTS <= lastVideoPTS {
                noteOutOfOrderDrop(track: "video", pts: originalPTS, last: lastVideoPTS)
                return
            }
            lastVideoPTS = originalPTS

            // The first frame after arming anchors the session timeline.
            if !sessionStarted {
                sessionStartTime = originalPTS
                writer.startSession(atSourceTime: originalPTS)
                sessionStarted = true
            }

            if needsResumeAdjustment {
                placeResumedSegment(firstSourcePTS: originalPTS, track: "video")
            }

            guard let reStamped = reStamp(sampleBuffer, offset: ptsOffset) else { return }
            let outPTS = CMSampleBufferGetPresentationTimeStamp(reStamped)

            // The hard guard: a video PTS that does not move forward is accepted by
            // append() and then kills the writer, so it never reaches the writer at all.
            if lastVideoOutPTS.isValid, outPTS <= lastVideoOutPTS {
                noteRestampDrop(track: "video", source: originalPTS, out: outPTS, lastOut: lastVideoOutPTS)
                return
            }
            if segmentStart.isValid, outPTS + Self.seamTolerance < segmentStart {
                noteRestampDrop(track: "video", source: originalPTS, out: outPTS, lastOut: segmentStart)
                return
            }

            if videoInput.append(reStamped), writer.status == .writing {
                lastVideoOutPTS = outPTS
            } else {
                noteAppendRejected(track: "video", writer: writer, source: originalPTS, out: outPTS)
            }
        }
    }


    func appendAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        writingQueue.sync {
            guard isWriting, !isPaused, armed, sessionStarted,
                  let writer = assetWriter else { return }
            guard writer.status == .writing else {
                reportFailureIfNeeded(writer)
                return
            }
            guard let audioInput = audioInput,
                  audioInput.isReadyForMoreMediaData else { return }

            let originalPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard originalPTS >= sessionStartTime else { return }  // drop audio before the video anchor

            if lastAudioPTS.isValid, originalPTS <= lastAudioPTS {
                noteOutOfOrderDrop(track: "audio", pts: originalPTS, last: lastAudioPTS)
                return
            }
            lastAudioPTS = originalPTS

            // A mic buffer is stamped at its first sample and is about 105 ms long, so its
            // stamp trails its arrival by a whole buffer. It can place a segment like a
            // frame can; the offset is measured in output time, so the lag does not leak in.
            if needsResumeAdjustment {
                placeResumedSegment(firstSourcePTS: originalPTS, track: "audio")
            }

            guard let reStamped = reStamp(sampleBuffer, offset: ptsOffset) else { return }
            let outPTS = CMSampleBufferGetPresentationTimeStamp(reStamped)

            if lastAudioOutPTS.isValid, outPTS <= lastAudioOutPTS {
                noteRestampDrop(track: "audio", source: originalPTS, out: outPTS, lastOut: lastAudioOutPTS)
                return
            }
            // Only at a seam: a buffer that would start before the segment holds sound from
            // the pause and would overlap what was already written. Steady-state buffers
            // are never compared against the previous END, so ordinary jitter costs nothing.
            if segmentStart.isValid, outPTS + Self.seamTolerance < segmentStart {
                noteRestampDrop(track: "audio", source: originalPTS, out: outPTS, lastOut: segmentStart)
                return
            }

            if audioInput.append(reStamped), writer.status == .writing {
                lastAudioOutPTS = outPTS
                lastAudioOutEnd = outPTS + Self.duration(of: reStamped)
            } else {
                noteAppendRejected(track: "audio", writer: writer, source: originalPTS, out: outPTS)
            }
        }
    }
    
    /// Maps a system-audio buffer's timestamp onto the timeline this writer is recording,
    /// or returns nil when the buffer belongs nowhere and must be dropped.
    ///
    /// The sidecar file is written by another object, but it must not invent its own zero
    /// point. All three sources are already stamped against the host clock (SCStream video
    /// and audio natively, the mic tap via `AVAudioTime.seconds(forHostTime:)`), so the
    /// only thing standing between them and alignment is knowing WHICH host instant became
    /// t=0 and how much paused time has been cut out since - and this writer is the only
    /// place that knows both. Reading them here, on the queue that owns them, is the same
    /// reasoning `appendAudioBuffer` uses to keep the mic in step with the picture.
    func systemAudioTimeline(for sampleBuffer: CMSampleBuffer) -> (anchor: CMTime, presentationTime: CMTime)? {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = Self.duration(of: sampleBuffer)
        return writingQueue.sync { () -> (anchor: CMTime, presentationTime: CMTime)? in
            guard isWriting, !isPaused, armed, sessionStarted else { return nil }
            guard pts >= sessionStartTime else { return nil }
            // A resume whose segment has not been placed yet: system audio places it like
            // a mic buffer or a frame would. Waiting for one of those instead would drop
            // all system audio for as long as the mic is off and the screen is static.
            if needsResumeAdjustment {
                placeResumedSegment(firstSourcePTS: pts, track: "system audio")
            }
            // ptsOffset is zero until the first resume and is then set at every resume so
            // the segment starts right after what both MP4 tracks and the sidecar already hold. Subtracting
            // it puts the sidecar on the same trimmed timeline as the MP4's own tracks,
            // while sessionStartTime stays the zero of both files.
            let presentationTime = pts - ptsOffset
            // Sound captured before the segment start belongs to the pause (or overlaps
            // the previous segment), exactly like the mic buffers the append path drops.
            if segmentStart.isValid, presentationTime + Self.seamTolerance < segmentStart { return nil }
            // A zero-length buffer still occupies its own timestamp in the sidecar.
            let end = duration > .zero ? presentationTime + duration
                                       : presentationTime + CMTime(value: 1, timescale: 1_000_000_000)
            if !lastSystemAudioOutEnd.isValid || end > lastSystemAudioOutEnd {
                lastSystemAudioOutEnd = end
            }
            return (sessionStartTime, presentationTime)
        }
    }

    /// Reports a mid-recording writer death to the owner, once. Runs on writingQueue.
    private func reportFailureIfNeeded(_ writer: AVAssetWriter) {
        guard writer.status == .failed, !failureReported else { return }
        failureReported = true
        onFailure?(writer.error)
    }

    /// Counts dropped non-monotonic buffers; logs the first so a recording that
    /// coincides with a system graphics storm leaves a diagnosable trace.
    private func noteOutOfOrderDrop(track: String, pts: CMTime, last: CMTime) {
        outOfOrderDrops += 1
        if outOfOrderDrops == 1 {
            LogManager.shared.log("⚠️ Writer: dropped out-of-order \(track) buffer (pts \(pts.seconds)s ≤ last \(last.seconds)s) — realtime timing glitch", type: .error)
        }
    }

    /// Counts buffers whose restamped time would not advance their own track; logs the
    /// first one of the recording with the numbers that explain it.
    private func noteRestampDrop(track: String, source: CMTime, out: CMTime, lastOut: CMTime) {
        restampDrops += 1
        if restampDrops == 1 {
            LogManager.shared.log("⚠️ Writer: dropped \(track) buffer at a resume seam - src \(Self.format(source)), out \(Self.format(out)), must be after \(Self.format(lastOut)), offset \(Self.format(ptsOffset)), resume #\(resumeCount)", type: .info)
        }
    }

    /// An append the writer refused, or one after which it went .failed. Logged once with
    /// the timing that led to it (the writer's own error does not say which sample it
    /// choked on), then reported right away instead of on the next buffer.
    private func noteAppendRejected(track: String, writer: AVAssetWriter, source: CMTime, out: CMTime) {
        if !appendRejectionLogged {
            appendRejectionLogged = true
            LogManager.shared.log("🔴 Writer: \(track) append rejected - src \(Self.format(source)), out \(Self.format(out)), last video out \(Self.format(lastVideoOutPTS)), last audio out \(Self.format(lastAudioOutPTS)) (end \(Self.format(lastAudioOutEnd))), offset \(Self.format(ptsOffset)), resume #\(resumeCount), status \(writer.status.rawValue) - \(Self.describeError(writer.error))", type: .error)
        }
        reportFailureIfNeeded(writer)
    }

    private static func format(_ time: CMTime) -> String {
        time.isValid ? String(format: "%.4fs", time.seconds) : "none"
    }

    /// A sample buffer's duration, computed from its sample count when CoreMedia does not
    /// carry one (LPCM buffers built from a tap sometimes do not).
    private static func duration(of sampleBuffer: CMSampleBuffer) -> CMTime {
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        if duration.isValid, duration > .zero { return duration }
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mSampleRate > 0 else { return .zero }
        return CMTime(value: CMTimeValue(CMSampleBufferGetNumSamples(sampleBuffer)),
                      timescale: CMTimeScale(asbd.mSampleRate))
    }

    /// Formats an AVAssetWriter error including the underlying OSStatus — the part
    /// that actually identifies CoreMedia failures (AVFoundation wraps them all in
    /// the generic -11800 "unknown error").
    static func describeError(_ error: Error?) -> String {
        guard let error = error as NSError? else { return "no error object" }
        var text = "\(error.domain) \(error.code): \(error.localizedDescription)"
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " — underlying \(underlying.domain) \(underlying.code)"
        }
        return text
    }

    private func reStamp(_ sampleBuffer: CMSampleBuffer, offset: CMTime) -> CMSampleBuffer? {
        guard offset.value != 0 else { return sampleBuffer }
        
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timingInfo = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timingInfo, entriesNeededOut: &count)
        
        for i in 0..<count {
            timingInfo[i].presentationTimeStamp = timingInfo[i].presentationTimeStamp - offset
            if timingInfo[i].decodeTimeStamp != .invalid {
                timingInfo[i].decodeTimeStamp = timingInfo[i].decodeTimeStamp - offset
            }
        }
        
        var outBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &outBuffer
        )
        return status == noErr ? outBuffer : nil
    }



    // MARK: - Finish

    func stopWriting() async -> URL? {
        guard isWriting, let writer = assetWriter else { return nil }

        // Flip the flag and mark inputs finished ON the writing queue, serialized
        // with in-flight appendVideo/AudioBuffer calls. Doing it on the caller's
        // thread used to race a tap callback that had already passed the guard,
        // making it append to an already-finished input → uncatchable NSException
        // crash at the exact moment a recording is saved.
        var totalDrops = 0
        var seamDrops = 0
        var resumes = 0
        writingQueue.sync {
            isWriting = false
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            totalDrops = outOfOrderDrops
            seamDrops = restampDrops
            resumes = resumeCount
        }
        if totalDrops > 0 {
            LogManager.shared.log("⚠️ Writer: dropped \(totalDrops) out-of-order buffer(s) this recording", type: .info)
        }
        if seamDrops > 0 {
            LogManager.shared.log("Writer: dropped \(seamDrops) buffer(s) at \(resumes) resume seam(s) this recording", type: .info)
        }

        return await withCheckedContinuation { continuation in
            writer.finishWriting {
                if writer.status == .completed {
                    continuation.resume(returning: self.outputURL)
                } else {
                    // print() goes nowhere for a Finder-launched app — log the real
                    // error (with underlying OSStatus) where it can be diagnosed.
                    LogManager.shared.log("🔴 Writer: finishWriting failed — \(Self.describeError(writer.error))", type: .error)
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Cancels an in-progress write and removes the partial file. Used by
    /// RecordingManager's start-failure rollback so a half-open writer (and its
    /// stranded partial .mp4) doesn't leak when audio/screen setup throws.
    func cancelWriting() {
        writingQueue.sync {
            isWriting = false
            if let writer = assetWriter, writer.status == .writing {
                writer.cancelWriting()
            }
        }
        try? FileManager.default.removeItem(at: outputURL)
    }
}

enum VideoWriterError: LocalizedError {
    case failedToStart

    var errorDescription: String? {
        switch self {
        case .failedToStart: return "Failed to start the video writer (disk full or unwritable location)"
        }
    }
}
