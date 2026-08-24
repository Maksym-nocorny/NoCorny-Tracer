import XCTest
@testable import NoCornyTracer

/// The persisted transcription axis. Both halves of the Codable wiring are load-bearing
/// and fail silently when missing: a key absent from `CodingKeys` never decodes (the field
/// is nil forever and every status is forgotten at relaunch), and a field absent from the
/// hand-written `encode(to:)` never persists at all. Worse, `loadRecordings` decodes with
/// `try?`, so a non-optional field would wipe the entire history of anyone upgrading.
final class TranscriptionStatusPersistenceTests: XCTestCase {

    private func makeRecording(_ path: String = "/tmp/persistence-test.mp4") -> Recording {
        Recording(fileURL: URL(fileURLWithPath: path), uploadStatus: .uploaded)
    }

    // MARK: - Roundtrip

    func testStatusAndErrorSurviveARoundtrip() throws {
        var recording = makeRecording()
        recording.transcriptionStatus = .failed
        recording.transcriptionError = "chunks_all_failed"

        let data = try JSONEncoder().encode([recording])
        let decoded = try JSONDecoder().decode([Recording].self, from: data)

        XCTAssertEqual(decoded.first?.transcriptionStatus, .failed,
                       "the status did not survive a save/load cycle - every failure is forgotten at relaunch")
        XCTAssertEqual(decoded.first?.transcriptionError, "chunks_all_failed",
                       "the row's answer to 'why' was lost with the process")
    }

    func testEveryStatusCaseRoundtrips() throws {
        for status in [TranscriptionStatus.idle, .queued, .transcribing, .done, .failed] {
            var recording = makeRecording()
            recording.transcriptionStatus = status
            let data = try JSONEncoder().encode(recording)
            let decoded = try JSONDecoder().decode(Recording.self, from: data)
            XCTAssertEqual(decoded.transcriptionStatus, status)
        }
    }

    /// encodeIfPresent's half of the contract: a nil field writes no key, so an older build
    /// reading this list (or a `try?` decode of it) has nothing new to choke on.
    func testAbsentFieldsEncodeToAbsentKeys() throws {
        let data = try JSONEncoder().encode(makeRecording())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["transcriptionStatus"],
                     "a nil status wrote a key anyway - encodeIfPresent is not being used")
        XCTAssertNil(object["transcriptionError"])
    }

    // MARK: - A list written before the field existed

    private func legacyRowJSON(transcriptSrt: String?) -> Data {
        var fields = [
            "\"id\": \"\(UUID().uuidString)\"",
            "\"fileURL\": \"file:///tmp/legacy-row.mp4\"",
            "\"createdAt\": 700000000",
            "\"duration\": 12.5",
            "\"uploadStatus\": \"uploaded\"",
        ]
        if let transcriptSrt {
            fields.append("\"transcriptSrt\": \"\(transcriptSrt)\"")
        }
        return Data("{ \(fields.joined(separator: ", ")) }".utf8)
    }

    func testARowWithoutTheNewKeysStillDecodes() throws {
        let decoded = try JSONDecoder().decode(Recording.self,
                                               from: legacyRowJSON(transcriptSrt: nil))
        XCTAssertNil(decoded.transcriptionStatus)
        XCTAssertNil(decoded.transcriptionError)
        XCTAssertEqual(decoded.uploadStatus, .uploaded,
                       "the old fields around the new ones stopped decoding")
    }

    /// The derivation for rows that predate the field: a transcript in hand - even one
    /// still inline in an unmigrated legacy row - means the work was done.
    func testALegacyInlineTranscriptDerivesDone() throws {
        let srt = "1\\n00:00:00,000 --> 00:00:01,000\\nhello"
        let decoded = try JSONDecoder().decode(Recording.self,
                                               from: legacyRowJSON(transcriptSrt: srt))
        XCTAssertNil(decoded.transcriptionStatus, "the fixture accidentally carried the new key")
        XCTAssertEqual(decoded.effectiveTranscriptionStatus, .done,
                       "a recording with a transcript reads as never transcribed")
    }

    func testNoFieldAndNoTranscriptDerivesIdle() throws {
        let decoded = try JSONDecoder().decode(Recording.self,
                                               from: legacyRowJSON(transcriptSrt: nil))
        XCTAssertEqual(decoded.effectiveTranscriptionStatus, .idle,
                       "a recording that was never transcribed claims something else happened")
    }

    /// An explicit status always beats the derivation - a stranded run flipped to `.failed`
    /// must stay failed even though its earlier pass left a transcript behind.
    func testAnExplicitStatusBeatsTheDerivation() throws {
        let srt = "1\\n00:00:00,000 --> 00:00:01,000\\nhello"
        var recording = try JSONDecoder().decode(Recording.self,
                                                 from: legacyRowJSON(transcriptSrt: srt))
        recording.transcriptionStatus = .failed
        XCTAssertEqual(recording.effectiveTranscriptionStatus, .failed)
    }
}
