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
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    // MARK: - Timing
    private var isFirstFrame = true
    private var sessionStartTime: CMTime = .zero
    private var isWriting = false

    // MARK: - Thread Safety
    private let writingQueue = DispatchQueue(label: "com.nocornytracer.videowriter", qos: .userInitiated)

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

        // Pixel buffer adaptor for frame conversion
        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: videoWidth,
            kCVPixelBufferHeightKey as String: videoHeight,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

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
        self.pixelBufferAdaptor = adaptor
        self.isFirstFrame = true
        self.isWriting = true

        writer.startWriting()
    }

    // MARK: - Appending Buffers

    func appendVideoBuffer(_ sampleBuffer: CMSampleBuffer) {
        writingQueue.sync {
            guard isWriting,
                  let writer = assetWriter,
                  writer.status == .writing,
                  let videoInput = videoInput,
                  videoInput.isReadyForMoreMediaData else { return }

            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            if isFirstFrame {
                sessionStartTime = timestamp
                writer.startSession(atSourceTime: timestamp)
                isFirstFrame = false
            }

            videoInput.append(sampleBuffer)
        }
    }

    func appendAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        writingQueue.sync {
            guard isWriting,
                  let writer = assetWriter,
                  writer.status == .writing,
                  let audioInput = audioInput,
                  audioInput.isReadyForMoreMediaData,
                  !isFirstFrame else { return } // Don't append audio before session starts

            audioInput.append(sampleBuffer)
        }
    }

    // MARK: - Finish

    func stopWriting() async -> URL? {
        guard isWriting, let writer = assetWriter else { return nil }

        isWriting = false
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

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
}
