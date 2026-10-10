import XCTest
@testable import NoCornyTracer

/// The 3 GB folder every 4.5.x Mac carries is removed once, and only once, the new model is
/// complete. Runs against a temporary base directory so no real model is touched.
final class LegacyModelReclaimTests: XCTestCase {

    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("nct-reclaim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    /// Lays down what `isModelDownloaded` looks for: the three packages with a non-empty
    /// weight blob each, and `config.json`.
    private func plantModel(_ variant: String, complete: Bool, bytes: Int = 1024) throws {
        let dir = LocalWhisperEngine.modelFolderURL(for: variant, under: base)
        for pkg in ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"] {
            let weights = dir.appendingPathComponent(pkg).appendingPathComponent("weights", isDirectory: true)
            try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
            let blob = Data(repeating: 1, count: complete ? bytes : 0)
            try blob.write(to: weights.appendingPathComponent("weight.bin"))
        }
        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        if !complete {
            try Data().write(to: dir.appendingPathComponent("weight.bin.incomplete"))
        }
    }

    private var legacy: String { LocalWhisperEngine.legacyVariants[0] }
    private var current: String { LocalWhisperEngine.variant }

    private func exists(_ variant: String) -> Bool {
        FileManager.default.fileExists(atPath: LocalWhisperEngine.modelFolderURL(for: variant, under: base).path)
    }

    func testTheLegacyModelGoesOnceTheNewOneIsComplete() throws {
        try plantModel(legacy, complete: true)
        try plantModel(current, complete: true)
        let cache = LocalWhisperEngine.huggingFaceDownloadCacheURL(for: legacy, under: base)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 512).write(to: cache.appendingPathComponent("stale.part"))

        let freed = LocalWhisperEngine.reclaimLegacyModels(under: base)

        XCTAssertFalse(exists(legacy), "the legacy folder is still there")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path), "Hub's staging cache for it was left behind")
        XCTAssertTrue(exists(current))
        // Three weight blobs, the two-byte config.json, and the staged fragment.
        XCTAssertEqual(freed, 3 * 1024 + 2 + 512)
    }

    /// Until the new model has fully landed, the legacy one is the only model that can
    /// serve a transcript, so it stays.
    func testTheLegacyModelStaysWhileTheNewOneIsIncomplete() throws {
        try plantModel(legacy, complete: true)
        try plantModel(current, complete: false)
        XCTAssertEqual(LocalWhisperEngine.reclaimLegacyModels(under: base), 0)
        XCTAssertTrue(exists(legacy))
    }

    func testTheLegacyModelStaysWhenThereIsNoNewOneAtAll() throws {
        try plantModel(legacy, complete: true)
        XCTAssertEqual(LocalWhisperEngine.reclaimLegacyModels(under: base), 0)
        XCTAssertTrue(exists(legacy))
    }

    /// The benchmark harness points `variant` at the legacy model to time it. A reclaim
    /// that ran then would delete the model under test: it did, once, on 2026-10-10.
    func testTheModelUnderTestIsNeverReclaimedAsItsOwnLeftover() throws {
        let original = LocalWhisperEngine.variant
        defer { LocalWhisperEngine.variant = original }
        LocalWhisperEngine.variant = legacy
        try plantModel(legacy, complete: true)
        XCTAssertEqual(LocalWhisperEngine.reclaimLegacyModels(under: base), 0)
        XCTAssertTrue(exists(legacy), "reclaimed the very model the engine was pointed at")
    }

    func testNothingToReclaimIsNotAnError() throws {
        try plantModel(current, complete: true)
        XCTAssertEqual(LocalWhisperEngine.reclaimLegacyModels(under: base), 0)
        XCTAssertTrue(exists(current))
    }

    /// The presence check the reclaim rests on, per variant: a half-written model must read
    /// as missing or the reclaim would delete the only working one.
    func testAnIncompleteModelReadsAsMissing() throws {
        try plantModel(current, complete: false)
        XCTAssertFalse(LocalWhisperEngine.isModelDownloaded(variant: current, under: base))
        try plantModel(legacy, complete: true)
        XCTAssertTrue(LocalWhisperEngine.isModelDownloaded(variant: legacy, under: base))
    }
}
