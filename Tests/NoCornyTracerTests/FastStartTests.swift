import XCTest
import AVFoundation
@testable import NoCornyTracer

/// The fast-start pass is the difference between a shared recording starting in a second
/// and in six, and nothing else in the suite looks at where the index ends up.
final class FastStartTests: XCTestCase {

    /// A tiny playable movie straight from AVAssetWriter - which is exactly the layout
    /// the app produces, index last.
    private static func makeWriterMovie() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("faststart-fixture-\(UUID().uuidString).mp4")
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
        try await Self.waitUntil("pixel buffer pool", { adaptor.pixelBufferPool != nil })
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBuffer)
        guard let pixelBuffer else { throw NSError(domain: "fixture", code: 1) }

        for seconds in [0.0, 1.0] {
            try await Self.waitUntil("writer ready", { input.isReadyForMoreMediaData })
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 1.5, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else { throw NSError(domain: "fixture", code: 2) }
        return url
    }

    private static func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "fixture", code: 9,
                      userInfo: [NSLocalizedDescriptionKey: "gave up waiting for \(what)"])
    }

    /// The writer's own output has the index last - that is the problem, stated as a fact
    /// about the fixture - and one pass moves it to the front without touching the content.
    func testThePassMovesTheIndexToTheFrontAndKeepsTheMovie() async throws {
        let url = try await Self.makeWriterMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(try FastStart.indexComesFirst(at: url), "fixture should carry the writer's end-of-file index")
        let before = try await AVURLAsset(url: url).load(.duration)

        let replaced = await FastStart.applyInPlace(recording: url)
        XCTAssertTrue(replaced)
        XCTAssertTrue(try FastStart.indexComesFirst(at: url))

        let after = AVURLAsset(url: url)
        let duration = try await after.load(.duration)
        XCTAssertEqual(duration.seconds, before.seconds, accuracy: 0.01)
        let videoTracks = try await after.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)

        let stem = url.deletingPathExtension().lastPathComponent
        let temp = url.deletingLastPathComponent().appendingPathComponent("\(stem)-faststart.mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path), "the temp copy must not outlive the pass")
    }

    /// A file that already has its index first is left exactly as it is.
    func testAFileWithTheIndexAlreadyFirstIsLeftAlone() async throws {
        let url = try await Self.makeWriterMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = await FastStart.applyInPlace(recording: url)
        let stamp = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        let replacedAgain = await FastStart.applyInPlace(recording: url)
        XCTAssertFalse(replacedAgain)
        let stampAfter = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertEqual(stampAfter, stamp)
    }

    /// The sweep takes only what an interrupted pass or merge leaves behind, and only once
    /// it is old enough to be nobody's work in progress.
    func testTheSweepRemovesOldLeftoversAndSparesEverythingElse() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("faststart-sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let twoHoursAgo = Date().addingTimeInterval(-7200)
        func drop(_ name: String, aged: Bool) throws {
            let url = dir.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            if aged {
                try FileManager.default.setAttributes([.modificationDate: twoHoursAgo], ofItemAtPath: url.path)
            }
        }
        try drop("take-faststart.mp4", aged: true)
        try drop("take-faststart.mp4.sb-abc-123", aged: true)
        try drop("take-merge.mp4", aged: true)
        try drop("take-merge-audio.m4a", aged: true)
        try drop("fresh-faststart.mp4", aged: false)   // a pass that may still be running
        try drop("take.mp4", aged: true)               // the recording itself
        try drop("take-system.m4a", aged: true)        // the system-audio sidecar

        XCTAssertEqual(FastStart.sweepOrphans(in: dir), 4)

        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertEqual(left, ["fresh-faststart.mp4", "take.mp4", "take-system.m4a"])
    }

    /// A header whose atom size runs past the file, or wraps around, is a damaged file
    /// and a quiet no - never a trap in the finishing phase.
    func testADamagedAtomSizeIsAQuietNo() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("faststart-damaged-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        var bytes: [UInt8] = []
        bytes += [0, 0, 0, 16] + Array("free".utf8) + [0, 0, 0, 0, 0, 0, 0, 0]
        // size = 1 -> 64-bit size follows: all ones, which wraps any offset it is added to.
        bytes += [0, 0, 0, 1] + Array("skip".utf8) + [UInt8](repeating: 0xFF, count: 8)
        try Data(bytes).write(to: url)

        XCTAssertFalse(try FastStart.indexComesFirst(at: url))
    }

    /// Nothing to work on is a quiet no, never a throw or a stray file.
    func testAMissingFileIsAQuietNo() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("faststart-missing-\(UUID().uuidString).mp4")
        let replaced = await FastStart.applyInPlace(recording: url)
        XCTAssertFalse(replaced)
    }
}
