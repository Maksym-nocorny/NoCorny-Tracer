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
    private var isFirstFrame = true
    private var sessionStartTime: CMTime = .zero
    private var isWriting = false
    
    private var ptsOffset: CMTime = .zero
    private var lastSourcePTS: CMTime = .zero
    private var isPaused = false
    private var needsResumeAdjustment = false


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

        // Write periodic movie fragments so a crash / power loss / force-quit leaves
        // a playable file instead of a moov-less, totally unreadable .mp4. The moov
        // atom is otherwise only written at finishWriting.
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 1)

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

        // Audio input settings — AAC at 48kHz stereo
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
        self.isFirstFrame = true
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
            self.isPaused = true
        }
    }
    
    func resume() {
        writingQueue.async {
            self.needsResumeAdjustment = true
            self.isPaused = false
        }
    }


    // MARK: - Appending Buffers

    func appendVideoBuffer(_ sampleBuffer: CMSampleBuffer) {
        writingQueue.sync {
            // Pause gating lives here (on writingQueue) instead of being read from
            // the capture thread off `RecordingManager.isPaused` — that was an
            // unsynchronized cross-thread Bool read (a data race).
            guard isWriting, !isPaused,
                  let writer = assetWriter,
                  writer.status == .writing,
                  let videoInput = videoInput,
                  videoInput.isReadyForMoreMediaData else { return }

            let originalPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            if isFirstFrame {
                sessionStartTime = originalPTS
                writer.startSession(atSourceTime: originalPTS)
                isFirstFrame = false
                lastSourcePTS = originalPTS
            }
            
            if needsResumeAdjustment {
                let gap = originalPTS - lastSourcePTS
                // We want the next segment to start immediately after the last segment
                // A tiny gap of 1 frame interval (based on fps) is standard
                let adjustment = gap - CMTime(value: 1, timescale: CMTimeScale(fps))
                if adjustment.seconds > 0 {
                    ptsOffset = ptsOffset + adjustment
                }
                needsResumeAdjustment = false
            }
            
            lastSourcePTS = originalPTS
            
            if let reStamped = reStamp(sampleBuffer, offset: ptsOffset) {
                videoInput.append(reStamped)
            }
        }
    }


    func appendAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        writingQueue.sync {
            guard isWriting, !isPaused,
                  let writer = assetWriter,
                  writer.status == .writing,
                  let audioInput = audioInput,
                  audioInput.isReadyForMoreMediaData,
                  !isFirstFrame else { return } // Don't append audio before session starts

            let originalPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            
            if needsResumeAdjustment {
                let gap = originalPTS - lastSourcePTS
                // Audio has 1024 samples per buffer usually, or smaller. 
                // We use 1/fps of video as a safe "resume gap" for both streams.
                let adjustment = gap - CMTime(value: 1, timescale: CMTimeScale(fps))
                if adjustment.seconds > 0 {
                    ptsOffset = ptsOffset + adjustment
                }
                needsResumeAdjustment = false
            }
            
            lastSourcePTS = originalPTS

            if let reStamped = reStamp(sampleBuffer, offset: ptsOffset) {
                audioInput.append(reStamped)
            }
        }
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
        writingQueue.sync {
            isWriting = false
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
        }

        return await withCheckedContinuation { continuation in
            writer.finishWriting {
                if writer.status == .completed {
                    continuation.resume(returning: self.outputURL)
                } else {
                    print("Asset writer finished with error: \(writer.error?.localizedDescription ?? "unknown")")
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
