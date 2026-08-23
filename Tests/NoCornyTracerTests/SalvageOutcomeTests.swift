import XCTest
import AVFoundation
@testable import NoCornyTracer

/// The residual named in commit 220a912: which of the two outcomes the salvage path picks.
///
/// It turns out reaching it does NOT need a live capture stack. `stopRecording` on an idle
/// manager only touches `screenRecorder.stopCapture()` (guarded by `stream == nil`) and
/// `audioCaptureManager.stopCapture()` (guarded by `engine == nil`) - both no-ops - and then
/// walks into the salvage branch because `videoWriter` is nil. All the branch needs is
/// `isRecording` flipped on (internal, settable under @testable) and a readable partial at
/// `currentFileURL`, which AVAssetWriter can produce headlessly.
final class SalvageOutcomeTests: XCTestCase {

    /// A tiny playable movie: one video track, duration comfortably past the 0.5s the
    /// salvage probe requires.
    private static func makePlayableMovie() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("salvage-fixture-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64,
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        while adaptor.pixelBufferPool == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBuffer)
        guard let pixelBuffer else { throw NSError(domain: "fixture", code: 1) }

        for seconds in [0.0, 1.0] {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 1.5, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else { throw NSError(domain: "fixture", code: 2) }
        return url
    }

    /// A recovered take is one nobody has seen: `.recovered`, never `.finished`. Marked as
    /// already saved, `applyingStopResult` reads "not in the list" as "deleted while the
    /// merge ran" and throws the rescued recording away.
    @MainActor
    func testASalvagedTakeReportsItWasNeverHandedOver() async throws {
        let url = try await Self.makePlayableMovie()
        defer { try? FileManager.default.removeItem(at: url) }

        let manager = RecordingManager()
        // The writer died: no videoWriter to finalise, but a readable partial on disk.
        manager.isRecording = true
        manager.currentFileURL = url

        let outcome = await manager.stopRecording(playSound: false)

        XCTAssertNotNil(outcome, "a readable partial was not salvaged at all")
        XCTAssertEqual(outcome?.wasHandedOver, false,
                       "a salvaged take nobody has seen claims it was already saved")
        if let outcome {
            XCTAssertNotNil(AppState.applyingStopResult(outcome, to: []),
                            "the recovered recording was dropped instead of added")
        }
        XCTAssertFalse(manager.isRecording, "the salvage path left a phantom recording behind")
        XCTAssertFalse(manager.isStopping, "the next stop would be a silent no-op")
    }

    /// The round-10 fix itself: `isStopping` comes down BEFORE the merge, together with
    /// `isRecording`. Held across the merge it made every stop door for a NEW recording a
    /// silent no-op for minutes, and a quit in that state killed the new take. The mutant
    /// "delete the early lowering" (the defer still resets it at return) passes the whole
    /// committed suite; this is the test that reaches it, through a real VideoWriter driven
    /// headlessly. Needs `videoWriter` visible to tests (one word: drop `private`).
    @MainActor
    func testTheStopLowersIsStoppingBeforeTheMerge() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("normal-stop-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = VideoWriter(outputURL: url, videoWidth: 64, videoHeight: 64, fps: 30)
        try writer.startWriting()
        writer.arm()
        for seconds in [0.0, 1.0] {
            writer.appendVideoBuffer(try Self.makeVideoSampleBuffer(atSeconds: seconds))
        }

        let manager = RecordingManager()
        manager.videoWriter = writer
        manager.currentFileURL = url
        manager.isRecording = true

        var stoppingAtHandOver: Bool?
        let outcome = await manager.stopRecording(playSound: false, onCaptureFinished: { _ in
            stoppingAtHandOver = manager.isStopping
        })

        XCTAssertEqual(outcome?.wasHandedOver, true, "the normal path did not finish the take")
        XCTAssertEqual(stoppingAtHandOver, false,
                       "isStopping held past finalisation makes every stop door a no-op during the merge")
        XCTAssertFalse(manager.isRecording)
    }

    private static func makeVideoSampleBuffer(atSeconds seconds: Double) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
        guard let pixelBuffer else { throw NSError(domain: "fixture", code: 3) }
        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDescription)
        guard let formatDescription else { throw NSError(domain: "fixture", code: 4) }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600),
            decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescription: formatDescription,
            sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
        guard let sampleBuffer else { throw NSError(domain: "fixture", code: 5) }
        return sampleBuffer
    }

    /// The other half of the branch: an unreadable partial comes back as nil, and the
    /// manager still resets rather than stranding a phantom recording.
    @MainActor
    func testAnUnreadablePartialComesBackAsNil() async {
        let manager = RecordingManager()
        manager.isRecording = true
        manager.currentFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("salvage-missing-\(UUID().uuidString).mp4")

        let outcome = await manager.stopRecording(playSound: false)

        XCTAssertNil(outcome)
        XCTAssertFalse(manager.isRecording)
    }
}

/// The hook BODIES. HookWiringTests pins that init subscribes them; nothing pinned what the
/// closures do, and an inert body passes the whole suite while every interrupted take goes
/// back in the bin. The closures are plain properties - a test can just call them.
final class InterruptedHookBehaviourTests: XCTestCase {

    @MainActor
    func testTheInterruptedHookActuallyKeepsTheTake() {
        let sandbox = SandboxDefaults.make()
        let previousShared = AppState.shared
        defer { AppState.shared = previousShared }

        let state = AppState(defaults: sandbox, connectsToTracer: false)
        let take = Recording(fileURL: URL(fileURLWithPath: "/tmp/interrupted-live.mp4"),
                             createdAt: Date(), duration: 42)

        state.recordingManager.onInterrupted?(take)

        XCTAssertTrue(state.recordings.contains(where: { $0.id == take.id }),
                      "the wired hook dropped the interrupted take on the floor")
        XCTAssertNotNil(sandbox.data(forKey: "savedRecordings"),
                        "the kept take was never persisted - it dies with the process")
    }
}
