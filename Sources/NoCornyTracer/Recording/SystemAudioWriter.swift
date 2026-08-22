import Foundation
import AVFoundation
import CoreMedia

/// Writes the system audio ScreenCaptureKit hands us into a sidecar `.m4a` next to the
/// recording, instead of mixing it into the MP4's audio input while recording.
///
/// Two reasons for the sidecar. First, separate tracks are the foundation for speaker
/// separation: "me" (mic) and "everyone else" (system) arriving as their own files is a
/// far stronger signal than a diarizer guessing who is who out of one mic that picked up
/// a speaker across the room. Second, feeding two live sources into a single
/// AVAssetWriterInput means real-time format conversion and interleaving on the capture
/// thread - the class of bug that silently desyncs audio halfway through a take and only
/// shows up when someone watches the recording back.
final class SystemAudioWriter {

    /// What `finish()` produced: the file, plus whether anything was actually playing.
    /// A sidecar full of digital silence is a merge that would cost minutes and change
    /// nothing, so the caller needs to be able to tell the two apart.
    struct Result {
        let url: URL
        let hasAudibleContent: Bool
    }

    // MARK: - Configuration
    private let outputURL: URL

    /// Anything quieter than this across a whole recording is a system that was not
    /// playing sound (encoder dither and DC offset live well below it), not a call.
    private static let silenceFloor: Float = 0.001  // ~ -60 dBFS

    // MARK: - AVAssetWriter
    private var assetWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?

    /// Serializes appends against `finish()`. Appending to an input that another thread
    /// has already marked finished is an uncatchable NSException, and the two run on
    /// different threads here (SCStream's audio queue vs. the main actor at stop).
    private let queue = DispatchQueue(label: "com.nocorny.tracer.systemaudiowriter", qos: .userInitiated)

    // All of the below are touched only on `queue`.
    private var isWriting = false
    private var sessionStarted = false
    private var lastPTS: CMTime = .invalid
    private var appendedBuffers = 0
    private var sawAudibleSamples = false
    private var failureLogged = false

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    /// Sidecar path for a recording: same folder, same base name, `-system.m4a`.
    static func sidecarURL(for recordingURL: URL) -> URL {
        let base = recordingURL.deletingPathExtension().lastPathComponent
        return recordingURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(base)-system.m4a")
    }

    // MARK: - Setup

    func startWriting() throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)

        // Stereo on purpose: system audio is the far end of a call or whatever the
        // machine is playing, and collapsing it to mono here would throw away
        // positional information a later separation pass may want.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw SystemAudioWriterError.cannotAddInput
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw writer.error ?? SystemAudioWriterError.failedToStart
        }

        self.assetWriter = writer
        self.audioInput = input
        self.isWriting = true
    }

    // MARK: - Appending

    /// Appends one system-audio buffer.
    ///
    /// - Parameters:
    ///   - presentationTime: the buffer's timestamp already mapped onto the recording's
    ///     timeline by `VideoWriter.systemAudioTimeline(for:)`.
    ///   - anchor: the host-clock instant the MP4 treats as t=0.
    func append(_ sampleBuffer: CMSampleBuffer, presentationTime: CMTime, anchor: CMTime) {
        queue.sync {
            guard isWriting, let writer = assetWriter, let input = audioInput else { return }
            guard writer.status == .writing else {
                logFailureOnce(writer)
                return
            }
            guard input.isReadyForMoreMediaData else { return }
            guard presentationTime >= anchor else { return }

            // Zero of this file is the video's zero. AVAssetWriter maps whatever source
            // time you open the session with onto time 0 of the output, so opening at
            // the exact host instant the MP4 anchored on makes sample 0 here and frame 0
            // there the same moment - the merge then needs no offset, and none of the
            // usual "which clock was that timestamp in" guesswork applies, because
            // SCStream video, SCStream audio and the mic tap are all stamped against the
            // host clock to begin with.
            if !sessionStarted {
                writer.startSession(atSourceTime: anchor)
                sessionStarted = true
            }

            // Same defence the video writer runs: a realtime source under load can emit a
            // non-increasing timestamp, which the writer accepts and then dies on later.
            if lastPTS.isValid, presentationTime <= lastPTS { return }
            lastPTS = presentationTime

            noteAudibleContent(in: sampleBuffer)

            guard let stamped = reStamped(sampleBuffer, to: presentationTime) else { return }
            if input.append(stamped) {
                appendedBuffers += 1
            } else {
                logFailureOnce(writer)
            }
        }
    }

    /// Shifts a buffer's timing so it lands where the recording's timeline wants it.
    /// The delta is zero unless the take was paused, in which case it is the paused
    /// time the video writer has already removed from its own tracks.
    private func reStamped(_ sampleBuffer: CMSampleBuffer, to pts: CMTime) -> CMSampleBuffer? {
        let original = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let delta = pts - original
        guard delta.value != 0 else { return sampleBuffer }

        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timingInfo = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timingInfo, entriesNeededOut: &count)

        for i in 0..<count {
            timingInfo[i].presentationTimeStamp = timingInfo[i].presentationTimeStamp + delta
            if timingInfo[i].decodeTimeStamp != .invalid {
                timingInfo[i].decodeTimeStamp = timingInfo[i].decodeTimeStamp + delta
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

    /// Notices the first sample loud enough to prove something was playing. Sampling
    /// every 16th float is plenty for a yes/no answer and keeps this off the profile of
    /// a capture callback. SCStream delivers 32-bit float PCM; anything else we do not
    /// try to interpret and simply assume is content.
    private func noteAudibleContent(in sampleBuffer: CMSampleBuffer) {
        guard !sawAudibleSamples else { return }
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else { return }
        guard asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            sawAudibleSamples = true
            return
        }

        try? sampleBuffer.withAudioBufferList { list, _ in
            for buffer in list {
                guard let data = buffer.mData else { continue }
                let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.assumingMemoryBound(to: Float.self)
                var i = 0
                while i < sampleCount {
                    if abs(samples[i]) > Self.silenceFloor {
                        sawAudibleSamples = true
                        return
                    }
                    i += 16
                }
            }
        }
    }

    /// One line per session, not per buffer - a dead writer fails on every append.
    private func logFailureOnce(_ writer: AVAssetWriter) {
        guard !failureLogged else { return }
        failureLogged = true
        LogManager.shared.log(
            "🔊 System audio: sidecar writer stopped accepting buffers - \(VideoWriter.describeError(writer.error)). Recording keeps the microphone track.",
            type: .error
        )
    }

    // MARK: - Finish

    /// Closes the sidecar. Returns nil when nothing usable was written, in which case
    /// the empty file is removed - the recording itself is untouched either way.
    func finish() async -> Result? {
        var hadSession = false
        var audible = false
        var buffers = 0
        queue.sync {
            guard isWriting else { return }
            isWriting = false
            audioInput?.markAsFinished()
            hadSession = sessionStarted
            audible = sawAudibleSamples
            buffers = appendedBuffers
        }

        guard let writer = assetWriter else { return nil }
        defer {
            assetWriter = nil
            audioInput = nil
        }

        // No session means no buffer ever made it past the arming gate (system audio
        // was silent from the start, or the stream never delivered any). finishWriting
        // on a writer with no session fails; skip straight to cleanup.
        guard hadSession, buffers > 0 else {
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: outputURL)
            LogManager.shared.log("🔊 System audio: nothing captured (no buffers) - no sidecar written", type: .info)
            return nil
        }

        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        guard writer.status == .completed else {
            LogManager.shared.log(
                "🔊 System audio: sidecar failed to finalize - \(VideoWriter.describeError(writer.error)). Recording is unaffected.",
                type: .error
            )
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }

        LogManager.shared.log("🔊 System audio: sidecar written (\(buffers) buffers, audible=\(audible)) → \(outputURL.lastPathComponent)")
        return Result(url: outputURL, hasAudibleContent: audible)
    }

    /// Throws away a sidecar for a recording that never really started (start-failure
    /// rollback), so no stray `-system.m4a` is left next to nothing.
    func cancel() {
        queue.sync {
            isWriting = false
            if let writer = assetWriter, writer.status == .writing {
                writer.cancelWriting()
            }
        }
        assetWriter = nil
        audioInput = nil
        try? FileManager.default.removeItem(at: outputURL)
    }
}

enum SystemAudioWriterError: LocalizedError {
    case cannotAddInput
    case failedToStart

    var errorDescription: String? {
        switch self {
        case .cannotAddInput: return "The system audio track could not be added to the sidecar file"
        case .failedToStart: return "Failed to start the system audio sidecar writer"
        }
    }
}
