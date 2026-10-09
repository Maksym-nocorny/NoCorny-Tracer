import XCTest
import AVFoundation
import CoreMedia
@testable import NoCornyTracer

/// Pause and resume against the REAL VideoWriter, driven headlessly with synthetic buffers.
///
/// Incident 2026-10-09: a take died right after its second pause/resume cycle with
/// AVFoundationErrorDomain -11800 / NSOSStatusErrorDomain -16364, and finishWriting left a
/// file with no moov. The cause was the resume adjustment: one shared "last source PTS" for
/// both tracks. A mic buffer is stamped at its FIRST sample and arrives about 115 ms later,
/// a screen frame arrives about 15 ms after its stamp. When the mic was the last append
/// before the pause and a video frame was the first after the resume, the gap was measured
/// from the stale mic stamp, too much time was cut, and the first resumed frame landed
/// BEFORE the last written one. The H.264 writer accepts that append and then dies.
///
/// The arrival model below copies those lags. Every buffer is handed to the writer in
/// arrival order, including the ones that arrive while paused (the capture stack keeps
/// delivering during a pause and the writer is the one that drops them).
final class VideoWriterPauseResumeTests: XCTestCase {

    // MARK: - Arrival model

    enum Track { case video, mic }

    struct Event {
        let track: Track
        /// Source timestamp, host-clock seconds.
        let pts: Double
        /// When the capture callback delivers it.
        let arrival: Double
    }

    enum Step {
        case buffer(Event)
        case pause
        case resume
    }

    static let frameInterval = 1.0 / 30.0
    static let videoLag = 0.015
    /// 5040 frames at 48 kHz: the size the incident log implies (19 buffers in 2 s).
    static let micFrames = 5040
    static let micDuration = Double(micFrames) / 48_000.0
    /// A mic buffer is stamped at its first sample and delivered once full, plus I/O.
    static let micLag = micDuration + 0.010

    /// Every video frame and mic buffer whose source time is in [start, end), in arrival order.
    static func events(from start: Double, to end: Double, micPhase: Double = 0.004,
                       skipVideo: ClosedRange<Double>? = nil) -> [Event] {
        var list: [Event] = []
        var n = 0
        while true {
            let pts = start + Double(n) * frameInterval
            if pts >= end { break }
            if !(skipVideo?.contains(pts) ?? false) {
                list.append(Event(track: .video, pts: pts, arrival: pts + videoLag))
            }
            n += 1
        }
        var k = 0
        while true {
            let pts = start + micPhase + Double(k) * micDuration
            if pts >= end { break }
            list.append(Event(track: .mic, pts: pts, arrival: pts + micLag))
            k += 1
        }
        return list.sorted { $0.arrival < $1.arrival }
    }

    /// Index of the first event of `track` arriving at or after `time`.
    static func firstIndex(of track: Track, arrivingAfter time: Double, in list: [Event]) -> Int {
        list.firstIndex { $0.track == track && $0.arrival >= time }!
    }

    /// A pause placed right AFTER the first `lastBefore` buffer arriving past `pauseAt`, and a
    /// resume placed right BEFORE the first `firstAfter` buffer arriving past `resumeAt`.
    static func insertCycle(into steps: inout [Step], list: [Event],
                            pauseAt: Double, lastBefore: Track,
                            resumeAt: Double, firstAfter: Track) {
        let pauseAfter = firstIndex(of: lastBefore, arrivingAfter: pauseAt, in: list)
        let resumeBefore = firstIndex(of: firstAfter, arrivingAfter: resumeAt, in: list)
        precondition(resumeBefore > pauseAfter)
        // Steps hold one entry per event plus the control steps already inserted, so find
        // the step position by arrival time rather than by index.
        func position(ofEventAt index: Int) -> Int {
            let target = list[index]
            return steps.firstIndex {
                if case .buffer(let e) = $0 { return e.arrival == target.arrival && e.track == target.track }
                return false
            }!
        }
        steps.insert(.pause, at: position(ofEventAt: pauseAfter) + 1)
        steps.insert(.resume, at: position(ofEventAt: resumeBefore))
    }

    // MARK: - Fixtures

    static func makeVideoSampleBuffer(pts: Double) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
        guard let pixelBuffer else { throw NSError(domain: "fixture", code: 1) }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, Int32(Int(pts * 30) % 256), CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDescription)
        guard let formatDescription else { throw NSError(domain: "fixture", code: 2) }
        // SCStream stamps in host nanoseconds.
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 1_000_000_000),
            decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescription: formatDescription,
            sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
        guard let sampleBuffer else { throw NSError(domain: "fixture", code: 3) }
        return sampleBuffer
    }

    /// Mirrors AudioCaptureManager.makeSampleBuffer: Float32 48 kHz mono LPCM, PTS in
    /// timescale 48000, data copied in from an AudioBufferList.
    static func makeMicSampleBuffer(pts: Double) throws -> CMSampleBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(micFrames))!
        pcm.frameLength = AVAudioFrameCount(micFrames)
        let samples = pcm.floatChannelData![0]
        for i in 0..<micFrames {
            samples[i] = 0.1 * sinf(Float(i) * 2 * .pi * 440 / 48_000)
        }
        var formatDesc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: format.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &formatDesc)
        guard let formatDesc else { throw NSError(domain: "fixture", code: 4) }
        var sampleBuffer: CMSampleBuffer?
        CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDesc,
            sampleCount: CMItemCount(micFrames),
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 48_000),
            packetDescriptions: nil, sampleBufferOut: &sampleBuffer)
        guard let sampleBuffer else { throw NSError(domain: "fixture", code: 5) }
        let status = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
            bufferList: pcm.audioBufferList)
        guard status == noErr else { throw NSError(domain: "fixture", code: 6) }
        return sampleBuffer
    }

    /// Polls for at most two seconds. Returns false on timeout instead of throwing, so a
    /// writer that died stops the feed and the assertions below report what happened.
    static func waitUntil(_ condition: () -> Bool) -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            usleep(5_000)
        }
        return false
    }

    // MARK: - Driver

    struct Outcome {
        let url: URL?
        let failure: Error??
        let stalledAt: Double?
        let videoTimes: [Double]
        let audioTimes: [Double]
        let audioCovered: Double
        let duration: Double
    }

    /// Feeds the steps to a real VideoWriter, stops it, and reads the file back.
    func run(_ steps: [Step], file: StaticString = #filePath, line: UInt = #line) async throws -> Outcome {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pause-resume-\(UUID().uuidString).mp4")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let writer = VideoWriter(outputURL: url, videoWidth: 64, videoHeight: 64,
                                 videoBitRate: 1_000_000, fps: 30)
        let failureBox = FailureBox()
        writer.onFailure = { failureBox.set($0) }
        try writer.startWriting()
        writer.arm()

        var paused = false
        var sessionStarted = false
        var stalledAt: Double?
        feed: for step in steps {
            switch step {
            case .pause:
                writer.pause(); paused = true
            case .resume:
                writer.resume(); paused = false
            case .buffer(let event):
                if failureBox.reported { break feed }
                // Waiting only matters while the writer takes the buffer; a paused writer
                // drops it before looking at the input.
                if !paused {
                    let ready: Bool
                    switch event.track {
                    case .video: ready = Self.waitUntil { writer.isReadyForVideo }
                    case .mic: ready = !sessionStarted || Self.waitUntil { writer.isReadyForAudio }
                    }
                    if !ready { stalledAt = event.pts; break feed }
                }
                switch event.track {
                case .video:
                    writer.appendVideoBuffer(try Self.makeVideoSampleBuffer(pts: event.pts))
                    if !paused { sessionStarted = true }
                case .mic:
                    writer.appendAudioBuffer(try Self.makeMicSampleBuffer(pts: event.pts))
                }
            }
        }

        let finished = await writer.stopWriting()
        var videoTimes: [Double] = []
        var audioTimes: [Double] = []
        var audioCovered = 0.0
        var duration = 0.0
        if let finished {
            let asset = AVURLAsset(url: finished)
            duration = try await asset.load(.duration).seconds
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                // Decoded output comes back in presentation order (passthrough would come
                // back in decode order, which B-frames legitimately reorder).
                videoTimes = try Self.readTimes(asset: asset, track: track, settings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                ]).map(\.pts)
            }
            if let track = try await asset.loadTracks(withMediaType: .audio).first {
                let times = try Self.readTimes(asset: asset, track: track, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                ])
                audioTimes = times.map(\.pts)
                audioCovered = times.reduce(0) { $0 + $1.duration }
            }
        }
        return Outcome(url: finished, failure: failureBox.value, stalledAt: stalledAt,
                       videoTimes: videoTimes, audioTimes: audioTimes,
                       audioCovered: audioCovered, duration: duration)
    }

    static func readTimes(asset: AVAsset, track: AVAssetTrack,
                          settings: [String: Any]) throws -> [(pts: Double, duration: Double)] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        XCTAssertTrue(reader.startReading(), "the file is not readable: \(String(describing: reader.error))")
        var times: [(Double, Double)] = []
        while let buffer = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            let duration = CMSampleBufferGetDuration(buffer)
            if CMSampleBufferGetNumSamples(buffer) > 0, pts.isValid {
                times.append((pts.seconds, duration.isValid ? duration.seconds : 0))
            }
        }
        XCTAssertEqual(reader.status, .completed, "reading stopped early: \(String(describing: reader.error))")
        return times
    }

    final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Error??
        func set(_ error: Error?) { lock.lock(); stored = .some(error); lock.unlock() }
        var value: Error?? { lock.lock(); defer { lock.unlock() }; return stored }
        var reported: Bool { value != nil }
    }

    /// The checks every scenario must pass: the writer stayed alive, the file is readable,
    /// both tracks move strictly forward, and the paused time is gone from the timeline.
    func assertHealthy(_ outcome: Outcome, expectedDuration: Double, maxVideoGap: Double = 0.25,
                       file: StaticString = #filePath, line: UInt = #line) {
        if let failure = outcome.failure {
            XCTFail("the writer died mid-recording: \(VideoWriter.describeError(failure ?? nil))",
                    file: file, line: line)
        }
        XCTAssertNil(outcome.stalledAt, "the writer stopped accepting buffers at src \(outcome.stalledAt ?? 0)",
                     file: file, line: line)
        XCTAssertNotNil(outcome.url, "stopWriting returned nil: the take is lost", file: file, line: line)
        guard outcome.url != nil else { return }

        XCTAssertGreaterThan(outcome.videoTimes.count, 0, "no video read back", file: file, line: line)
        for (a, b) in zip(outcome.videoTimes, outcome.videoTimes.dropFirst()) where b <= a {
            XCTFail("video goes backwards in the file: \(b) after \(a)", file: file, line: line)
            break
        }
        XCTAssertGreaterThan(outcome.audioTimes.count, 0, "no audio read back", file: file, line: line)
        for (a, b) in zip(outcome.audioTimes, outcome.audioTimes.dropFirst()) where b <= a {
            XCTFail("audio goes backwards in the file: \(b) after \(a)", file: file, line: line)
            break
        }
        // No pause left in the picture: the largest jump between frames is a resume seam,
        // not seconds of frozen screen.
        let largestGap = zip(outcome.videoTimes, outcome.videoTimes.dropFirst()).map { $1 - $0 }.max() ?? 0
        XCTAssertLessThan(largestGap, maxVideoGap, "a pause was left in the video timeline", file: file, line: line)
        XCTAssertEqual(outcome.duration, expectedDuration, accuracy: 0.3,
                       "the file does not have the recorded length minus the pauses", file: file, line: line)
        // Audio may lose one mic buffer at each resume seam, not more.
        XCTAssertEqual(outcome.audioCovered, expectedDuration, accuracy: 0.45,
                       "audio is missing from the recording", file: file, line: line)
    }

    // MARK: - Tests

    /// The incident ordering. Cycle 1: video last before the pause, video first after the
    /// resume (survived in the incident too). Cycle 2: MIC last before the pause, VIDEO
    /// first after the resume. Before the fix the first resumed frame was stamped about
    /// 40 ms behind the last written one and the writer died with -11800 / -16364.
    func testSecondResumeWithMicLastAndVideoFirstKeepsTheWriterAlive() async throws {
        let list = Self.events(from: 100.0, to: 114.0)
        var steps = list.map(Step.buffer)
        Self.insertCycle(into: &steps, list: list, pauseAt: 102.0, lastBefore: .video,
                         resumeAt: 103.5, firstAfter: .video)
        Self.insertCycle(into: &steps, list: list, pauseAt: 106.0, lastBefore: .mic,
                         resumeAt: 107.5, firstAfter: .video)

        let outcome = try await run(steps)

        // Recorded: about 100-102, 103.5-106, 107.5-114 of source time.
        assertHealthy(outcome, expectedDuration: 2.0 + 2.5 + 6.5)
    }

    /// Every combination of "which track was written last before the pause" and "which
    /// track arrives first after the resume", two cycles each. The resume adjustment must
    /// not depend on arrival order.
    func testEveryArrivalOrderAroundAResumeKeepsBothTracksMovingForward() async throws {
        for lastBefore in [Track.video, .mic] {
            for firstAfter in [Track.video, .mic] {
                let list = Self.events(from: 100.0, to: 110.0)
                var steps = list.map(Step.buffer)
                Self.insertCycle(into: &steps, list: list, pauseAt: 101.5, lastBefore: lastBefore,
                                 resumeAt: 103.0, firstAfter: firstAfter)
                Self.insertCycle(into: &steps, list: list, pauseAt: 105.0, lastBefore: lastBefore,
                                 resumeAt: 106.0, firstAfter: firstAfter)

                let outcome = try await run(steps)
                XCTContext.runActivity(named: "last before pause: \(lastBefore), first after resume: \(firstAfter)") { _ in
                    assertHealthy(outcome, expectedDuration: 1.5 + 2.0 + 4.0)
                }
            }
        }
    }

    /// A static screen sends no frames for a while after the resume, so only mic buffers
    /// arrive. The resumed audio must be written, not held back until a frame shows up.
    func testAResumeOnAStaticScreenStillRecordsTheMicrophone() async throws {
        let list = Self.events(from: 100.0, to: 109.0, skipVideo: 104.0...105.5)
        var steps = list.map(Step.buffer)
        Self.insertCycle(into: &steps, list: list, pauseAt: 102.0, lastBefore: .mic,
                         resumeAt: 104.0, firstAfter: .mic)

        let outcome = try await run(steps)

        // 100-102 and 104-109; the frozen picture from 104 to 105.5 is real recorded time.
        assertHealthy(outcome, expectedDuration: 2.0 + 5.0, maxVideoGap: 1.7)
        XCTAssertLessThan(outcome.videoTimes.count, Int(7.0 * 30) - 30,
                          "the fixture did not leave a gap in the video")
    }

    /// The plain case, benign ordering: record, pause, resume, stop. The file is readable
    /// and the pause is not in it.
    func testAPlainPauseAndResumeProducesAReadableFileWithoutThePause() async throws {
        let list = Self.events(from: 100.0, to: 106.0)
        var steps = list.map(Step.buffer)
        Self.insertCycle(into: &steps, list: list, pauseAt: 102.0, lastBefore: .video,
                         resumeAt: 104.0, firstAfter: .mic)

        let outcome = try await run(steps)

        assertHealthy(outcome, expectedDuration: 2.0 + 2.0)
    }

    // MARK: - System audio sidecar

    /// A system-audio buffer as SCStream delivers it: 48 kHz mono, 10 ms.
    static func makeSystemAudioSampleBuffer(pts: Double, frames: Int = 480) throws -> CMSampleBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        var formatDesc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: format.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &formatDesc)
        guard let formatDesc else { throw NSError(domain: "fixture", code: 7) }
        var sampleBuffer: CMSampleBuffer?
        CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDesc,
            sampleCount: CMItemCount(frames),
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 48_000),
            packetDescriptions: nil, sampleBufferOut: &sampleBuffer)
        guard let sampleBuffer else { throw NSError(domain: "fixture", code: 8) }
        let status = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
            bufferList: pcm.audioBufferList)
        guard status == noErr else { throw NSError(domain: "fixture", code: 9) }
        return sampleBuffer
    }

    /// Mic off, system audio on. The screen goes static five seconds before the pause while
    /// system audio keeps playing. Returns the sidecar times handed out before the pause and
    /// after the resume, in order, plus the writer for further feeding.
    private func runStaticScreenSystemAudioCycle(
        firstAfterResume: Track?
    ) throws -> (writer: VideoWriter, url: URL, failures: FailureBox, before: [Double], after: [Double]) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pause-resume-sys-\(UUID().uuidString).mp4")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let writer = VideoWriter(outputURL: url, videoWidth: 64, videoHeight: 64,
                                 videoBitRate: 1_000_000, fps: 30)
        let failures = FailureBox()
        writer.onFailure = { failures.set($0) }
        try writer.startWriting()
        writer.arm()

        func sys(_ pts: Double) throws -> Double? {
            writer.systemAudioTimeline(for: try Self.makeSystemAudioSampleBuffer(pts: pts))?.presentationTime.seconds
        }

        // Frames only from 100 to 110, system audio from 100 to 115.
        var before: [Double] = []
        var n = 0
        while 100.0 + Double(n) * Self.frameInterval < 110.0 {
            XCTAssertTrue(Self.waitUntil { writer.isReadyForVideo })
            writer.appendVideoBuffer(try Self.makeVideoSampleBuffer(pts: 100.0 + Double(n) * Self.frameInterval))
            n += 1
        }
        for k in 0..<1500 {
            if let t = try sys(100.0 + Double(k) * 0.01) { before.append(t) }
        }
        writer.pause()
        for k in 0..<500 {
            XCTAssertNil(try sys(115.0 + Double(k) * 0.01), "system audio was mapped while paused")
        }
        writer.resume()

        if firstAfterResume == .video {
            XCTAssertTrue(Self.waitUntil { writer.isReadyForVideo })
            writer.appendVideoBuffer(try Self.makeVideoSampleBuffer(pts: 120.0))
        }
        var after: [Double] = []
        for k in 0..<200 {
            if let t = try sys(120.0 + Double(k) * 0.01) { after.append(t) }
        }
        return (writer, url, failures, before, after)
    }

    /// Mic off, static screen across the resume: no frame and no mic buffer arrives to
    /// place the segment. System audio must place it and keep flowing into the sidecar,
    /// after everything the sidecar already holds.
    func testSystemAudioOnAStaticScreenWithTheMicOffIsKeptAfterAResume() async throws {
        let run = try runStaticScreenSystemAudioCycle(firstAfterResume: nil)

        XCTAssertEqual(run.before.count, 1500, "pre-pause system audio was dropped")
        XCTAssertEqual(run.after.count, 200, "post-resume system audio was dropped until a frame arrived")
        if let last = run.before.last, let first = run.after.first {
            XCTAssertGreaterThan(first, last, "post-resume system audio maps behind the sidecar's last buffer")
            // The pause is cut out: the segment starts where the pre-pause audio ended.
            XCTAssertEqual(first, last + 0.01, accuracy: 0.002)
        }
        for (a, b) in zip(run.after, run.after.dropFirst()) where b <= a {
            XCTFail("system audio goes backwards after the resume: \(b) after \(a)")
            break
        }

        // A frame after the system audio placed the segment still moves the video forward.
        XCTAssertTrue(Self.waitUntil { run.writer.isReadyForVideo })
        run.writer.appendVideoBuffer(try Self.makeVideoSampleBuffer(pts: 122.0))
        let finished = await run.writer.stopWriting()
        XCTAssertNil(run.failures.value, "the writer died mid-recording")
        XCTAssertNotNil(finished, "stopWriting returned nil: the take is lost")
        if let finished {
            let asset = AVURLAsset(url: finished)
            let track = try await asset.loadTracks(withMediaType: .video).first
            XCTAssertNotNil(track)
            if let track {
                let times = try Self.readTimes(asset: asset, track: track, settings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                ]).map(\.pts)
                for (a, b) in zip(times, times.dropFirst()) where b <= a {
                    XCTFail("video goes backwards in the file: \(b) after \(a)")
                    break
                }
                // Frame at src 122 sits 2 s into the segment that starts at 15 s of output.
                XCTAssertEqual(times.last ?? 0, 17.0, accuracy: 0.05)
            }
        }
    }

    /// Mic off, the screen was static for five seconds before the pause, and a frame is the
    /// first buffer after the resume. The segment must start after the sidecar's last
    /// buffer, not one frame after the stale last frame, or the sidecar drops the first
    /// five seconds of post-resume system audio.
    func testAResumeAfterAStaticScreenStartsAfterTheSidecarsLastSystemAudio() async throws {
        let run = try runStaticScreenSystemAudioCycle(firstAfterResume: .video)

        XCTAssertEqual(run.after.count, 200)
        if let last = run.before.last, let first = run.after.first {
            XCTAssertGreaterThan(first, last, "post-resume system audio maps behind the sidecar's last buffer")
            XCTAssertEqual(first, last + 0.01, accuracy: 0.002)
        }
        let finished = await run.writer.stopWriting()
        XCTAssertNil(run.failures.value, "the writer died mid-recording")
        XCTAssertNotNil(finished, "stopWriting returned nil: the take is lost")
    }
}
