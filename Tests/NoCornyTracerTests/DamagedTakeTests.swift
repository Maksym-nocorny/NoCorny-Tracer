import XCTest
import AVFoundation
@testable import NoCornyTracer

/// The 2026-10-09 incident: the writer died mid-recording (-11800 / -16364), the stop kept
/// the partial .mp4 on disk but returned nil, and the library showed nothing at all. The
/// user took the recording for deleted; it was rebuilt by hand from the mdat. These tests
/// pin the safety net: an unreadable partial on disk is a visible, damaged take that the
/// pipeline never uploads, transcribes, or cleans up, and that stays damaged across launches.
final class DamagedTakeTests: XCTestCase {

    /// The shape a non-fragmented writer leaves when it dies before finishWriting: an
    /// `ftyp` box and an `mdat` full of samples, with no `moov` index anywhere.
    private static func makeUnindexedPartial() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("damaged-partial-\(UUID().uuidString).mp4")
        var bytes = Data()
        func box(_ type: String, _ payload: Data) {
            var size = UInt32(8 + payload.count).bigEndian
            bytes.append(Data(bytes: &size, count: 4))
            bytes.append(type.data(using: .ascii)!)
            bytes.append(payload)
        }
        box("ftyp", "mp42".data(using: .ascii)! + Data([0, 0, 0, 1]) + "mp41mp42isom".data(using: .ascii)!)
        box("mdat", Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
        try bytes.write(to: url)
        return url
    }

    private static func damagedRecording(status: UploadStatus = .notUploaded,
                                         fileURL: URL = URL(fileURLWithPath: "/tmp/damaged-row.mp4")) -> Recording {
        var r = Recording(fileURL: fileURL, createdAt: Date(), duration: 330, uploadStatus: status)
        r.damagedReason = Recording.writerFailureDamageReason
        return r
    }

    // MARK: Salvage

    /// The incident path end to end, minus the capture stack: a writer with no file to
    /// finalise (videoWriter nil) and an unreadable partial on disk. It must come back as a
    /// take, marked damaged, as `.recovered` so the caller adds it, with the file untouched.
    @MainActor
    func testAnUnreadablePartialIsKeptAsADamagedTake() async throws {
        let url = try Self.makeUnindexedPartial()
        defer { try? FileManager.default.removeItem(at: url) }
        let sizeBefore = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber

        let manager = RecordingManager()
        manager.isRecording = true
        manager.currentFileURL = url
        manager.accumulatedDuration = 42

        let outcome = await manager.stopRecording(playSound: false)

        let take = try XCTUnwrap(outcome?.take, "the unreadable partial vanished from the library again")
        XCTAssertEqual(outcome?.wasHandedOver, false,
                       "a damaged take nobody has seen claims it was already saved")
        XCTAssertEqual(take.damagedReason, Recording.writerFailureDamageReason)
        XCTAssertEqual(take.fileURL, url)
        XCTAssertEqual(take.fileSize, sizeBefore?.uint64Value)
        XCTAssertEqual(take.duration, 42, accuracy: 0.5,
                       "the damaged row lost the only length figure it can show")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the salvage deleted the partial")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
                       sizeBefore, "the salvage modified the partial")
        if let outcome {
            let list = AppState.applyingStopResult(outcome, to: [])
            XCTAssertEqual(list?.first?.id, take.id, "the damaged take was dropped instead of added")
        }
        XCTAssertFalse(manager.isRecording, "the salvage path left a phantom recording behind")
        XCTAssertFalse(manager.isStopping, "the next stop would be a silent no-op")
    }

    /// An empty file has nothing to recover, so there is no row to show for it.
    @MainActor
    func testAnEmptyPartialComesBackAsNil() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("damaged-empty-\(UUID().uuidString).mp4")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let manager = RecordingManager()
        manager.isRecording = true
        manager.currentFileURL = url

        let outcome = await manager.stopRecording(playSound: false)

        XCTAssertNil(outcome)
        XCTAssertFalse(manager.isRecording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the salvage deleted a file")
    }

    // MARK: Pipeline gate

    func testTheUploadGateRefusesADamagedRecording() {
        XCTAssertFalse(AppState.mayEnterPipeline(Self.damagedRecording()),
                       "a damaged file would be uploaded, transcribed and then deleted")
        XCTAssertTrue(AppState.mayEnterPipeline(Recording(fileURL: URL(fileURLWithPath: "/tmp/ok.mp4"))),
                      "the gate refuses ordinary takes too")
    }

    /// The retry door, through a real AppState: a damaged row offered for retry stays as it
    /// is. Without the gate the row flips to `.uploading` and the pipeline is claimed.
    @MainActor
    func testRetryUploadRefusesADamagedRecording() async throws {
        let sandbox = SandboxDefaults.make()
        let previousShared = AppState.shared
        defer { AppState.shared = previousShared }

        let url = try Self.makeUnindexedPartial()
        defer { try? FileManager.default.removeItem(at: url) }
        let damaged = Self.damagedRecording(status: .failed, fileURL: url)

        let state = AppState(defaults: sandbox, connectsToTracer: false)
        state.recordings = [damaged]

        await state.retryUpload(damaged)

        XCTAssertEqual(state.recordings.first?.uploadStatus, .failed, "retry started an upload of a damaged file")
        XCTAssertFalse(state.hasActivePipeline, "the pipeline was claimed for a damaged file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// The hand-off every stop path shares: a damaged take is kept and saved, but never
    /// claimed by the pipeline. The interrupted hook is the one door a test can call.
    @MainActor
    func testADamagedTakeIsKeptButNeverProcessed() {
        let sandbox = SandboxDefaults.make()
        let previousShared = AppState.shared
        defer { AppState.shared = previousShared }

        let state = AppState(defaults: sandbox, connectsToTracer: false)
        let take = Self.damagedRecording()

        state.recordingManager.onInterrupted?(take)

        XCTAssertEqual(state.recordings.first(where: { $0.id == take.id })?.damagedReason,
                       Recording.writerFailureDamageReason, "the damaged take is not in the library")
        XCTAssertNotNil(sandbox.data(forKey: "savedRecordings"), "the damaged take was never persisted")
        XCTAssertFalse(state.hasActivePipeline, "a damaged take was sent to the pipeline")
    }

    // MARK: Persistence

    func testDamagedReasonRoundTripsAndOldDataDecodesAsNil() throws {
        let damaged = Self.damagedRecording()
        let decoded = try JSONDecoder().decode(Recording.self, from: JSONEncoder().encode(damaged))
        XCTAssertEqual(decoded.damagedReason, Recording.writerFailureDamageReason)

        // A row written before the field existed.
        var legacy = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(Recording(fileURL: URL(fileURLWithPath: "/tmp/old.mp4")))) as! [String: Any]
        legacy.removeValue(forKey: "damagedReason")
        let old = try JSONDecoder().decode(Recording.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.damagedReason)
        XCTAssertFalse(old.isDamaged)
    }

    /// The launch reconcile turns a `.notUploaded` row into "Not uploaded yet - tap to
    /// upload". For a damaged row that is an offer to upload an unreadable file.
    func testADamagedRowStaysDamagedAcrossALaunch() throws {
        let sandbox = SandboxDefaults.make()
        let previousShared = AppState.shared
        defer { AppState.shared = previousShared }

        let damaged = Self.damagedRecording(status: .notUploaded)
        let ordinary = Recording(fileURL: URL(fileURLWithPath: "/tmp/ordinary.mp4"), uploadStatus: .notUploaded)
        sandbox.set(try JSONEncoder().encode([damaged, ordinary]), forKey: "savedRecordings")

        let state = AppState(defaults: sandbox, connectsToTracer: false)

        let row = try XCTUnwrap(state.recordings.first { $0.id == damaged.id })
        XCTAssertEqual(row.damagedReason, Recording.writerFailureDamageReason)
        XCTAssertEqual(row.uploadStatus, .notUploaded, "the launch reconcile offered to upload a damaged file")
        XCTAssertNil(row.uploadError)
        XCTAssertEqual(state.recordings.first { $0.id == ordinary.id }?.uploadStatus, .failed,
                       "the ordinary stranded row lost its reconcile")
    }

    /// The signed-out drawer's "clips waiting" count: a damaged take is not waiting for Dropbox.
    func testADamagedTakeIsNotCountedAsWaitingForUpload() {
        let rows = [Self.damagedRecording(), Recording(fileURL: URL(fileURLWithPath: "/tmp/waiting.mp4"))]
        XCTAssertEqual(LocalClipQueue.waitingCount(recordings: rows) { _ in true }, 1)
    }
}
