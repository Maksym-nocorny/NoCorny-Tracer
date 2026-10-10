import XCTest
@testable import NoCornyTracer

/// When the on-device model gets re-compiled in the background, and when it must not.
///
/// The incident behind it: on 2026-09-16 the first local transcript after the 4.5.3 update
/// sat on "Queued" for three and a half minutes while Core ML rebuilt the model the system
/// cache had dropped. The schedule is only worth anything if it fires after exactly the
/// events that drop that cache, and stays quiet under a take.
final class LocalModelWarmupPolicyTests: XCTestCase {

    private let os = "Version 26.6.2 (Build 25G83)"
    private let now = Date(timeIntervalSince1970: 1_789_550_000)

    private let model = "openai_whisper-large-v3-v20240930_turbo"

    private func stamp(app: String = "4.5.4", os: String? = nil, ago: TimeInterval = 3600, variant: String? = "openai_whisper-large-v3-v20240930_turbo") -> LocalModelWarmup.Stamp {
        LocalModelWarmup.Stamp(appBuild: app, osBuild: os ?? self.os, loadedAt: now.addingTimeInterval(-ago), variant: variant)
    }

    private func reason(_ stamp: LocalModelWarmup.Stamp?) -> LocalModelWarmup.Reason? {
        LocalModelWarmup.reason(stamp: stamp, appBuild: "4.5.4", osBuild: os, now: now, variant: model)
    }

    /// The update window: a transcribe on the legacy model stamped this build, then the new
    /// model landed. Without this the new model would never be compiled ahead of a take.
    func testALoadOfAnotherModelWarms() {
        XCTAssertEqual(reason(stamp(variant: "openai_whisper-large-v3_turbo")), .modelChanged)
    }

    /// Stamps written by 4.5.x carry no variant; they must still decode, and they warm.
    func testAStampWithoutAVariantWarms() {
        XCTAssertEqual(reason(stamp(variant: nil)), .modelChanged)
    }

    // MARK: - Reason

    func testNoLoadOnRecordWarms() {
        // Everyone who downloaded the model before this build has no stamp, and the first
        // launch after updating to it is exactly the cold case.
        XCTAssertEqual(reason(nil), .neverLoaded)
    }

    func testARecentLoadOnTheSameBuildsStaysQuiet() {
        XCTAssertNil(reason(stamp()))
    }

    func testAnAppUpdateWarms() {
        XCTAssertEqual(reason(stamp(app: "4.5.3")), .appUpdated(from: "4.5.3", to: "4.5.4"))
    }

    func testAMacOSUpdateWarms() {
        XCTAssertEqual(reason(stamp(os: "Version 26.5.2 (Build 25F84)")), .systemUpdated)
    }

    func testASecurityResponseWithTheSameMarketingVersionStillWarms() {
        // The build is what moves on a rapid security response; comparing "26.6.2" alone
        // would sleep through it.
        XCTAssertEqual(reason(stamp(os: "Version 26.6.2 (Build 25G90)")), .systemUpdated)
    }

    func testIdleJustUnderTheThresholdStaysQuiet() {
        XCTAssertNil(reason(stamp(ago: LocalModelWarmup.idleThreshold - 60)))
    }

    func testIdleAtTheThresholdWarms() {
        XCTAssertEqual(reason(stamp(ago: LocalModelWarmup.idleThreshold)), .idle(days: 7))
    }

    func testTheThresholdLeavesRoomBeforeArgmaxsFortnight() {
        XCTAssertLessThanOrEqual(LocalModelWarmup.idleThreshold, 10 * 86_400)
    }

    func testALoadStampedInTheFutureDoesNotWarmOnEveryTick() {
        // A clock set back after a load must not read as "idle for -3 days, warm now".
        XCTAssertNil(reason(stamp(ago: -3 * 86_400)))
    }

    // MARK: - Gate

    func testAnIdleLocalUserWithAModelMayWarm() {
        XCTAssertTrue(LocalModelWarmup.mayWarm(engineIsLocal: true, modelReady: true, busy: false, lowPower: false, gaveUp: false, ramGB: 16))
    }

    func testEveryBlockerHoldsTheWarmOnItsOwn() {
        let blocked: [(String, Bool)] = [
            ("cloud engine", LocalModelWarmup.mayWarm(engineIsLocal: false, modelReady: true, busy: false, lowPower: false, gaveUp: false, ramGB: 16)),
            ("no model on disk", LocalModelWarmup.mayWarm(engineIsLocal: true, modelReady: false, busy: false, lowPower: false, gaveUp: false, ramGB: 16)),
            ("recording or transcribing", LocalModelWarmup.mayWarm(engineIsLocal: true, modelReady: true, busy: true, lowPower: false, gaveUp: false, ramGB: 16)),
            ("low power mode", LocalModelWarmup.mayWarm(engineIsLocal: true, modelReady: true, busy: false, lowPower: true, gaveUp: false, ramGB: 16)),
            ("a warm already failed", LocalModelWarmup.mayWarm(engineIsLocal: true, modelReady: true, busy: false, lowPower: false, gaveUp: true, ramGB: 16)),
            // There the warm is a GPU load: a joining transcribe starts a second GPU init
            // (SIGABRT), and a GPU init error wipes the model with nobody watching.
            ("an 8 GB Mac", LocalModelWarmup.mayWarm(engineIsLocal: true, modelReady: true, busy: false, lowPower: false, gaveUp: false, ramGB: 8)),
        ]
        for (label, allowed) in blocked {
            XCTAssertFalse(allowed, "warm allowed despite: \(label)")
        }
    }

    func testTheFirstLookWaitsOutSomeoneWhoOpenedTheAppToRecord() {
        // The compile cannot be cancelled; at two minutes a user is often still picking a
        // window, not yet "busy".
        XCTAssertGreaterThanOrEqual(LocalModelWarmup.launchDelay, 600)
    }

    // MARK: - Pipeline claims

    func testAClaimHoldsUntilItsRunReleasesIt() {
        let claims = PipelineClaims()
        let id = UUID()
        XCTAssertTrue(claims.isEmpty)
        claims.claim(id)
        XCTAssertFalse(claims.isEmpty)
        claims.release(id)
        XCTAssertTrue(claims.isEmpty)
    }

    func testARetryOfTheSameRecordingKeepsItsOwnClaim() {
        // A retried upload re-enters the pipeline for the same id; the first run finishing
        // must not declare the app idle under the second.
        let claims = PipelineClaims()
        let id = UUID()
        claims.claim(id)
        claims.claim(id)
        claims.release(id)
        XCTAssertFalse(claims.isEmpty)
        claims.release(id)
        XCTAssertTrue(claims.isEmpty)
    }

    func testAStrayReleaseDoesNotGoNegative() {
        let claims = PipelineClaims()
        let id = UUID()
        claims.release(id)
        claims.claim(id)
        XCTAssertFalse(claims.isEmpty, "a release before the claim swallowed it")
    }

    // MARK: - Stamp storage

    func testTheStampSurvivesARoundTrip() {
        let defaults = SandboxDefaults.make()
        let original = stamp(app: "4.5.3")
        LocalModelWarmup.saveStamp(original, to: defaults)
        XCTAssertEqual(LocalModelWarmup.loadStamp(from: defaults), original)
    }

    func testAnUnreadableStampCountsAsNoLoadAndWarms() {
        let defaults = SandboxDefaults.make()
        defaults.set(Data("not json".utf8), forKey: LocalModelWarmup.stampKey)
        let loaded = LocalModelWarmup.loadStamp(from: defaults)
        XCTAssertNil(loaded)
        XCTAssertEqual(reason(loaded), .neverLoaded)
    }

    // MARK: - Queued label

    func testALocalRunWaitingOnTheCompileSaysSo() {
        let preparing = TranscriptionStatusCluster.isPreparingLocalModel(engine: .localWhisper, modelPhase: .preparing)
        XCTAssertTrue(preparing)
        XCTAssertEqual(TranscriptionStatusCluster.queuedLabel(preparingModel: preparing), "Preparing model…")
    }

    func testACloudRunDoesNotBorrowABackgroundWarmsPhase() {
        let preparing = TranscriptionStatusCluster.isPreparingLocalModel(engine: .cloudGemini, modelPhase: .preparing)
        XCTAssertFalse(preparing)
        XCTAssertEqual(TranscriptionStatusCluster.queuedLabel(preparingModel: preparing), "Queued")
    }

    func testALocalRunWithAReadyModelIsPlainlyQueued() {
        XCTAssertFalse(TranscriptionStatusCluster.isPreparingLocalModel(engine: .localWhisper, modelPhase: .ready))
    }
}
