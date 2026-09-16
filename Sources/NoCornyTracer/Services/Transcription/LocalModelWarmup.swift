import Foundation

/// Keeps the on-device model compiled before anyone is waiting on it.
///
/// The Neural Engine compile of large-v3-turbo is cached by macOS, not by us. The `.mlmodelc`
/// files in Application Support never change; the specialised copy lives in the system's Core
/// ML cache, and the system decides when it goes. Apple names an OS update, low disk and a
/// modified model (WWDC23, "Improve Core ML integration with async prediction"); Argmax adds
/// roughly 14 days without a load. There is no public API to pin that cache or even to ask
/// whether it is still there.
///
/// On 2026-09-16 the first local transcript after the 4.5.3 update sat on "Queued" for three
/// and a half minutes while that compile ran: decoder 20s, encoder 2m16s, per
/// ANECompilerService in the unified log. Which trigger had evicted the cache could not be
/// seen from the Mac. So rather than guess, warm whenever the cache has PLAUSIBLY gone cold,
/// while nobody is waiting. A warm cache answers the load in about two seconds, so a warm
/// that turns out unnecessary costs almost nothing, and a necessary one moves minutes out of
/// the user's way.
@MainActor
final class LocalModelWarmup {

    static let shared = LocalModelWarmup()

    // MARK: - Policy (pure, covered by LocalModelWarmupPolicyTests)

    /// The last time a model load succeeded, and on what. A load is what fills the cache and,
    /// as far as anyone outside Apple can tell, what resets its idle clock.
    struct Stamp: Codable, Equatable {
        let appBuild: String
        let osBuild: String
        let loadedAt: Date
    }

    enum Reason: Equatable {
        /// No load on record: the model predates this mechanism, or it has never loaded.
        case neverLoaded
        case appUpdated(from: String, to: String)
        case systemUpdated
        case idle(days: Int)

        var logDescription: String {
            switch self {
            case .neverLoaded: return "no load on record"
            case .appUpdated(let from, let to): return "app updated \(from) → \(to)"
            case .systemUpdated: return "macOS updated"
            case .idle(let days): return "no load for \(days) days"
            }
        }
    }

    /// Half of Argmax's ~14 days, so a user who transcribes locally once a week or so never
    /// meets the eviction, and a user who does not is re-warmed well before it.
    nonisolated static let idleThreshold: TimeInterval = 7 * 24 * 3600

    /// Why the cache may have gone cold since the last load, or nil if it should still be warm.
    ///
    /// The app build counts although no source ties the cache key to it: every cold compile
    /// on record (24.08, 06.09, 16.09) followed either an app update or a macOS update, and
    /// warming on a false positive is a two-second load.
    nonisolated static func reason(stamp: Stamp?, appBuild: String, osBuild: String, now: Date) -> Reason? {
        guard let stamp else { return .neverLoaded }
        if stamp.appBuild != appBuild { return .appUpdated(from: stamp.appBuild, to: appBuild) }
        if stamp.osBuild != osBuild { return .systemUpdated }
        let idle = now.timeIntervalSince(stamp.loadedAt)
        guard idle >= idleThreshold else { return nil }
        return .idle(days: Int(idle / 86_400))
    }

    /// Whether a warm may start right now. Every "no" is a state where the compile is either
    /// pointless or in the way:
    /// - `engineIsLocal == false`: the cloud engine never loads this model. Three minutes of
    ///   Neural Engine and battery for nobody.
    /// - `modelReady == false`: nothing to compile, or a download is still writing it.
    /// - `busy`: recording, stopping or transcribing. The compile runs out of process and
    ///   cannot be cancelled once started, so it must not start under a take; and a
    ///   transcribe loads the model itself, which warms the cache anyway.
    /// - `lowPower`: the user asked the Mac to save energy.
    /// - `gaveUp`: a warm already failed in this session. Its compile may still be running,
    ///   and a second `WhisperKit` init beside it is the corruption the model host exists to
    ///   prevent.
    /// - `ramGB <= 8`: there the model host skips the Neural Engine and loads on the GPU
    ///   directly, so a warm IS a GPU load. A transcribe that joins it gives up after 30s and
    ///   starts a second GPU init beside it, which Metal answers with SIGABRT; and a GPU init
    ///   error wipes the 1.5 GB model, which in the background would happen with nobody told.
    ///   The GPU compile there is about 50 seconds, so the warm buys little for that risk.
    nonisolated static func mayWarm(
        engineIsLocal: Bool,
        modelReady: Bool,
        busy: Bool,
        lowPower: Bool,
        gaveUp: Bool,
        ramGB: UInt64
    ) -> Bool {
        engineIsLocal && modelReady && !busy && !lowPower && !gaveUp && ramGB > 8
    }

    // MARK: - Stamp storage

    nonisolated static let stampKey = "localModelLastLoad"

    nonisolated static func loadStamp(from defaults: UserDefaults) -> Stamp? {
        guard let data = defaults.data(forKey: stampKey) else { return nil }
        return try? JSONDecoder().decode(Stamp.self, from: data)
    }

    nonisolated static func saveStamp(_ stamp: Stamp, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(stamp) else { return }
        defaults.set(data, forKey: stampKey)
    }

    /// Called by the model host after every successful load, whoever asked for it: a
    /// transcribe warms the cache exactly as well as a background warm does. Skipped under
    /// tests, which must not write the developer's real defaults.
    nonisolated static func recordLoad() {
        guard !LogManager.isRunningUnderTests else { return }
        saveStamp(Stamp(appBuild: currentAppBuild, osBuild: currentOSBuild, loadedAt: Date()), to: .standard)
    }

    nonisolated static var currentAppBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    }

    /// "Version 26.6.2 (Build 25G83)". The build is the part that changes on every update,
    /// including the security responses that keep the marketing version.
    nonisolated static var currentOSBuild: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    // MARK: - Scheduling

    /// First look after launch. Ten minutes, not two: the compile cannot be cancelled once
    /// it starts, and someone who opened the app to record is often still picking a window
    /// at the two-minute mark, not recording yet, so "not busy" would let it start under
    /// their take. By ten they are recording (the tick skips) or they were not here to record.
    static let launchDelay: TimeInterval = 600
    /// Later looks. Only the idle rule can become true while the app runs, so this is cheap
    /// and rarely does anything; a busy tick simply waits for the next one.
    static let checkInterval: TimeInterval = 1800

    private var timer: Timer?
    private var isWarming = false
    private var gaveUp = false
    private var engineIsLocal: () -> Bool = { false }
    private var isBusy: () -> Bool = { true }

    private init() {}

    /// Called once at launch. Every gate is read at fire time, so switching the engine or
    /// starting a recording silences the next tick without any re-wiring.
    func start(engineIsLocal: @escaping () -> Bool, isBusy: @escaping () -> Bool) {
        self.engineIsLocal = engineIsLocal
        self.isBusy = isBusy
        timer?.invalidate()
        let timer = Timer(
            fire: Date().addingTimeInterval(Self.launchDelay),
            interval: Self.checkInterval,
            repeats: true
        ) { _ in
            Task { @MainActor in LocalModelWarmup.shared.tick() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard !isWarming,
              LocalWhisperEngine.isAvailable,
              Self.mayWarm(
                engineIsLocal: engineIsLocal(),
                modelReady: LocalWhisperEngine.isModelDownloaded(),
                busy: isBusy(),
                lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                gaveUp: gaveUp,
                ramGB: ProcessInfo.processInfo.physicalMemory / 1_073_741_824
              ),
              let reason = Self.reason(
                stamp: Self.loadStamp(from: .standard),
                appBuild: Self.currentAppBuild,
                osBuild: Self.currentOSBuild,
                now: Date()
              )
        else { return }

        isWarming = true
        Task { @MainActor in
            defer { self.isWarming = false }
            do {
                try await LocalWhisperEngine.warmCache(reason: reason.logDescription)
            } catch {
                self.gaveUp = true
                LogManager.shared.log("🎙️ Local: background warm did not finish (\(error)), not retrying until the next launch", type: .error)
            }
        }
    }
}
