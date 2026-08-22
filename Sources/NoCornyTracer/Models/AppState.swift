import Foundation
import SwiftUI
import Combine
import ServiceManagement

/// Central app state managing all sub-managers and user preferences
@Observable
final class AppState {
    // MARK: - Managers
    let recordingManager = RecordingManager()
    let dropboxAuthManager = DropboxAuthManager()
    let dropboxUploadManager = DropboxUploadManager()
    let tracerAPIClient = TracerAPIClient()
    // The Gemini proxy authenticates with the signed-in user's Tracer token,
    // so AINamingService needs a closure that can read the current token from
    // tracerAPIClient. @ObservationIgnored + lazy lets us reference one stored
    // property from another's initializer (otherwise @Observable's macro turns
    // the property into a computed one and `lazy` won't apply).
    @ObservationIgnored
    lazy var aiNamingService: AINamingService = AINamingService(
        proxyClient: GeminiProxyClient(
            tokenProvider: { [weak self] in self?.tracerAPIClient.apiToken }
        ),
        transcriptionClient: TranscriptionProxyClient(
            tokenProvider: { [weak self] in self?.tracerAPIClient.apiToken }
        ),
        preferredKind: { [weak self] in self?.transcriptionEngine ?? .cloudGemini },
        expectedSpeakers: { [weak self] in self?.expectedSpeakers ?? .auto }
    )
    let hotkeyManager = HotkeyManager()
    let cameraManager = CameraManager()

    // MARK: - Singleton for AppDelegate access
    static weak var shared: AppState?

    // MARK: - Theme
    enum AppTheme: String, CaseIterable {
        case light, dark

        var colorScheme: ColorScheme {
            switch self {
            case .light: return .light
            case .dark: return .dark
            }
        }

        var iconName: String {
            switch self {
            case .light: return "sun.max"
            case .dark: return "moon"
            }
        }

        var displayName: String { rawValue.capitalized }
    }

    // MARK: - Tabs
    enum MainTab: String, CaseIterable {
        case recorder = "Recorder"
        case recordings = "Recordings"
        case settings = "Settings"
    }
    var selectedTab: MainTab = .recorder

    // MARK: - State
    var recordings: [Recording] = []
    /// Recordings whose speaker labels are being recomputed right now. Drives the row spinner
    /// and stops a second re-run being started on top of a running one.
    private(set) var reapplyingSpeakers: Set<UUID> = []
    /// Why the last re-run for a recording produced nothing, in words meant for the person
    /// reading the row. Cleared when a re-run starts.
    private(set) var speakerReapplyErrors: [UUID: String] = [:]
    var dropboxUsedSpace: UInt64 = 0
    var dropboxAllocatedSpace: UInt64 = 0
    var isSyncingDropbox: Bool = false

    var selectedMicrophoneID: String?
    var isMicrophoneEnabled: Bool = true
    /// When off (default), the mic is captured raw for maximum fidelity. When on, Apple Voice
    /// Processing (Voice Isolation, AGC off) suppresses background noise at the cost of some quality.
    var reduceBackgroundNoise: Bool = false {
        didSet {
            UserDefaults.standard.set(reduceBackgroundNoise, forKey: "reduceBackgroundNoise")
        }
    }
    /// Off by default: system audio is other people talking, so recording it is a
    /// deliberate choice rather than something a screen recorder quietly starts doing.
    var recordSystemAudio: Bool = false {
        didSet {
            UserDefaults.standard.set(recordSystemAudio, forKey: "recordSystemAudio")
        }
    }
    /// Which engine transcribes. Defaults to the cloud so nothing changes for anyone
    /// already using the app; on-device is opt-in until its model is downloaded, which is
    /// a deliberate 1.5 GB decision rather than something that happens on first launch.
    /// How many people the user expects in a recording. A default for new recordings only:
    /// `DiarizationAudioCache` keeps the audio, so a wrong answer is corrected per recording
    /// from the Recordings list rather than by recording again.
    var expectedSpeakers: ExpectedSpeakers = .auto {
        didSet {
            UserDefaults.standard.set(expectedSpeakers.rawValue, forKey: "expectedSpeakers")
        }
    }
    var transcriptionEngine: TranscriptionEngineKind = .cloudGemini {
        didSet {
            UserDefaults.standard.set(transcriptionEngine.rawValue, forKey: "transcriptionEngine")
        }
    }
    /// Label transcript cues with who said them. Off by default: it costs minutes of Core ML
    /// on a long recording and a ~130 MB model download the first time, neither of which is a
    /// fair surprise for someone who only wanted subtitles.
    var diarizationEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(diarizationEnabled, forKey: "diarizationEnabled")
        }
    }
    var appTheme: AppTheme = .light {
        didSet {
            UserDefaults.standard.set(appTheme.rawValue, forKey: "appTheme")
            updateAppAppearance()
        }
    }
    var autoUploadEnabled: Bool = true
    var launchAtLogin: Bool = false {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
        }
    }
    var videoResolution: VideoResolution = .hd1080 {
        didSet {
            UserDefaults.standard.set(videoResolution.rawValue, forKey: "videoResolution")
        }
    }
    var videoFrameRate: VideoFrameRate = .fps30 {
        didSet {
            UserDefaults.standard.set(videoFrameRate.rawValue, forKey: "videoFrameRate")
        }
    }
    
    // MARK: - Camera Preferences
    var isCameraEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isCameraEnabled, forKey: "isCameraEnabled")
            updateCameraState()
        }
    }
    var selectedCameraDeviceID: String? {
        didSet {
            UserDefaults.standard.set(selectedCameraDeviceID, forKey: "selectedCameraDeviceID")
            cameraManager.selectedDeviceID = selectedCameraDeviceID
        }
    }

    // MARK: - Persistence Keys
    private let recordingsKey = "savedRecordings"
    private static let hasLaunchedBeforeKey = "hasLaunchedBefore"
    private static let dropboxUsedSpaceKey = "dropboxUsedSpace"
    private static let dropboxAllocatedSpaceKey = "dropboxAllocatedSpace"
    private static let lastTracerSyncAtKey = "lastTracerSyncAt"
    private static let noiseSuggestionDismissedKey = "noiseSuggestionDismissedForever"

    /// Set to true on first launch to show a dialog asking about launch at login
    var showLaunchAtLoginPrompt = false

    /// Tracks whether the floating "noisy environment" suggestion toast is currently shown.
    /// Transient; guards against re-presenting while already visible.
    private(set) var showNoiseSuggestion = false
    /// Once the user picks "Don't suggest again", we never show the suggestion toast again.
    private var noiseSuggestionDismissedForever = false
    /// Presents/hides the floating suggestion toast. Set by the app scene's window host. Driven via
    /// a closure (not SwiftUI `.onChange`) because the toast must appear DURING recording, when the
    /// main window is hidden and its view graph can't be relied on to observe state changes.
    @ObservationIgnored
    var presentNoiseSuggestion: ((Bool) -> Void)?

    /// Presents the Permissions window (and brings the app forward) when a recording is
    /// blocked on a missing permission. Set by the app scene's window host — like
    /// `presentNoiseSuggestion` — because the gate fires while the main window is hidden
    /// (both Start paths `orderOut` the window before awaiting `startRecording`).
    @ObservationIgnored
    var presentPermissionsGate: (([PermissionsManager.RecordingPermission]) -> Void)?

    /// Polls Tracer for the current Dropbox connection state. Lets the macOS app
    /// notice within ~60s when the user disconnects (or switches accounts) on the
    /// web — without needing a recording / upload to trigger a token refresh.
    private var dropboxStatusTimer: Timer?
    /// True once the first `syncDropboxFromTracer` of this session has finished.
    /// Until then, any sync (launch Task, didBecomeActive, heartbeat — they can
    /// race) is treated as a launch restore and must NOT trigger the
    /// "Dropbox Connected" success sheet.
    private var hasCompletedInitialDropboxSync = false

    init() {
        if let themeRaw = UserDefaults.standard.string(forKey: "appTheme"),
           let theme = AppTheme(rawValue: themeRaw) {
            self.appTheme = theme
        }
        self.launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
        self.reduceBackgroundNoise = UserDefaults.standard.bool(forKey: "reduceBackgroundNoise")
        self.recordSystemAudio = UserDefaults.standard.bool(forKey: "recordSystemAudio")
        self.diarizationEnabled = UserDefaults.standard.bool(forKey: "diarizationEnabled")
        if let speakersRaw = UserDefaults.standard.string(forKey: "expectedSpeakers"),
           let speakers = ExpectedSpeakers(rawValue: speakersRaw) {
            self.expectedSpeakers = speakers
        }
        if let engineRaw = UserDefaults.standard.string(forKey: "transcriptionEngine"),
           let engine = TranscriptionEngineKind(rawValue: engineRaw) {
            self.transcriptionEngine = engine
        }
        self.noiseSuggestionDismissedForever = UserDefaults.standard.bool(forKey: Self.noiseSuggestionDismissedKey)
        self.isCameraEnabled = UserDefaults.standard.bool(forKey: "isCameraEnabled")
        self.selectedCameraDeviceID = UserDefaults.standard.string(forKey: "selectedCameraDeviceID")
        if let resRaw = UserDefaults.standard.string(forKey: "videoResolution"),
           let res = VideoResolution(rawValue: resRaw) {
            self.videoResolution = res
        }
        if let fpsRaw = UserDefaults.standard.object(forKey: "videoFrameRate") as? Int,
           let fps = VideoFrameRate(rawValue: fpsRaw) {
            self.videoFrameRate = fps
        }
        
        let storedUsed = UserDefaults.standard.double(forKey: Self.dropboxUsedSpaceKey)
        let storedAllocated = UserDefaults.standard.double(forKey: Self.dropboxAllocatedSpaceKey)
        if storedAllocated > 0 {
            self.dropboxUsedSpace = UInt64(storedUsed)
            self.dropboxAllocatedSpace = UInt64(storedAllocated)
        }

        loadRecordings()
        // Ensure system state matches our stored preference
        updateLaunchAtLogin()
        // Check if this is the first launch
        checkFirstLaunch()
        // Start global hotkeys (temporarily disabled for debugging)
        // hotkeyManager.start(appState: self)
        
        // Setup initial camera state
        cameraManager.isEnabled = self.isCameraEnabled
        if let id = self.selectedCameraDeviceID {
            cameraManager.selectedDeviceID = id
        } else {
            // Restore newly selected device ID from discovery to AppState
            self.selectedCameraDeviceID = cameraManager.selectedDeviceID
        }
        updateCameraState()

        // Set shared reference for AppDelegate access
        AppState.shared = self

        // When the mic detects a noisy room mid-recording (and noise reduction is off), surface
        // the suggestion toast — unless the user has permanently dismissed it.
        recordingManager.audioCaptureManager.onEnvironmentNoisy = { [weak self] in
            guard let self else { return }
            guard !self.noiseSuggestionDismissedForever, !self.reduceBackgroundNoise else { return }
            guard !self.showNoiseSuggestion else { return }
            self.showNoiseSuggestion = true
            self.presentNoiseSuggestion?(true)
        }

        // A writer that dies mid-recording silently drops every further frame. This is
        // now rare — the periodic fragment flush that used to fail with -16341 is gone
        // (see VideoWriter) — so on the off chance it still happens, stop right away and
        // ship whatever finalized through the normal pipeline. We deliberately do NOT
        // auto-restart into a fresh take: a surprise "recording started again" is worse
        // than a clean stop, and the salvage-then-restart loop was itself the disruptive
        // behavior users hit when the flush kept dying.
        recordingManager.onWriterFailed = { [weak self] in
            Task { @MainActor in await self?.recoverFromWriterFailure() }
        }

        // Wire up proxied Dropbox: the DropboxAuthManager asks Tracer for a fresh
        // access token, and "Connect Dropbox" opens the web settings page.
        dropboxAuthManager.fetchProxiedToken = { [weak self] in
            // self == nil means the app is tearing down — report transient so no
            // state gets destroyed. Otherwise pass the typed result straight
            // through (parsing + connected/expiry handling live in the client).
            guard let self = self else { return .transientFailure }
            return await self.tracerAPIClient.fetchDropboxAccessToken()
        }
        dropboxAuthManager.openWebDropboxSettings = { [weak self] in
            self?.openTracerSettings()
        }
        dropboxAuthManager.isTracerSignedIn = { [weak self] in
            self?.tracerAPIClient.isSignedIn ?? false
        }
        dropboxAuthManager.disconnectProxied = { [weak self] in
            await self?.tracerAPIClient.disconnectDropbox()
        }

        // Tracer rejected our token (HTTP 401) → the client already signed out.
        // Mirror a manual sign-out's Dropbox teardown, but deliberately do NOT
        // wipe the recordings library: the rows are still valid and will refresh
        // once the user signs in again.
        tracerAPIClient.onTokenRevoked = { [weak self] in
            self?.dropboxAuthManager.clearProxiedState()
        }

        // If the user is already signed in to Tracer at launch, try to pick up
        // their Dropbox connection from the server immediately. Run these
        // sequentially so the Dropbox-status check has a chance to wipe the
        // local library cache (in case the user disconnected on the web while
        // the app was closed) BEFORE reloadRecordingsFromTracer would otherwise
        // run an incremental `?since=` sync that wouldn't notice the deletions.
        if tracerAPIClient.isSignedIn {
            Task {
                await self.syncDropboxFromTracer()
                await self.reloadRecordingsFromTracer()
            }
        }

        // Apply theme appearance after app finishes launching (NSApp is nil during init)
        DispatchQueue.main.async { [weak self] in
            self?.updateAppAppearance()
        }

        // Start polling Dropbox connection state, and refresh on app activation
        // so a Disconnect/Connect on the web reflects in the macOS app within
        // ~60s (or instantly when the window is brought to the front).
        startDropboxStatusPolling()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.requestDropboxSyncFromUserActivity()
        }
        // didBecomeActive only fires on app-level focus change (e.g. Cmd+Tab).
        // didBecomeKey fires when any of our windows becomes the key window —
        // catching the case where the user clicks back into the app's window
        // from a browser tab without an app switch (the most common path
        // after connecting Dropbox on the web).
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.requestDropboxSyncFromUserActivity()
        }
    }

    /// Debounced entry point for event-driven Dropbox syncs (window focus,
    /// app activation). The 60s heartbeat bypasses this — it has its own
    /// cadence. Debouncing avoids back-to-back requests when several focus
    /// events fire in quick succession (e.g. didBecomeActive + didBecomeKey
    /// arriving together when the user Cmd+Tabs back).
    private static let dropboxSyncDebounceInterval: TimeInterval = 3.0
    private var lastDropboxSyncRequestAt: Date?

    private func requestDropboxSyncFromUserActivity() {
        guard tracerAPIClient.isSignedIn else { return }
        if let last = lastDropboxSyncRequestAt,
           Date().timeIntervalSince(last) < Self.dropboxSyncDebounceInterval {
            return
        }
        lastDropboxSyncRequestAt = Date()
        Task { await self.syncDropboxFromTracer() }
    }

    private func startDropboxStatusPolling() {
        dropboxStatusTimer?.invalidate()
        let timer = Timer(timeInterval: 60.0, repeats: true) { [weak self] _ in
            guard let self = self, self.tracerAPIClient.isSignedIn else { return }
            Task { await self.syncDropboxFromTracer() }
        }
        // Tolerance lets the OS coalesce the wake — fine for a 60s heartbeat.
        timer.tolerance = 10.0
        RunLoop.main.add(timer, forMode: .common)
        dropboxStatusTimer = timer
    }

    // MARK: - Theme Appearance

    func updateAppAppearance() {
        guard let app = NSApp else { return }
        switch appTheme {
        case .light:
            app.appearance = NSAppearance(named: .aqua)
        case .dark:
            app.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func checkFirstLaunch() {
        if !UserDefaults.standard.bool(forKey: Self.hasLaunchedBeforeKey) {
            UserDefaults.standard.set(true, forKey: Self.hasLaunchedBeforeKey)
            showLaunchAtLoginPrompt = true
        }
    }

    // MARK: - Launch at Login
    func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status == .notRegistered {
                    try SMAppService.mainApp.register()
                    print("⚙️ Startup: Registered for launch at login")
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                    print("⚙️ Startup: Unregistered launch at login")
                }
            }
        } catch {
            print("⚙️ Startup: Failed to update launch at login: \(error)")
        }
    }
    
    // MARK: - Camera State
    private func updateCameraState() {
        cameraManager.isEnabled = isCameraEnabled
        
        if isCameraEnabled {
            Task { await cameraManager.startSession() }
        } else {
            cameraManager.stopSession()
        }
    }

    // MARK: - Noise Suggestion

    /// User accepted the "noisy environment" suggestion. Enabling persists and takes effect on the
    /// NEXT recording — voice processing can't be hot-swapped on a live engine without an audio gap.
    func enableNoiseReductionFromSuggestion() {
        reduceBackgroundNoise = true
        showNoiseSuggestion = false
        presentNoiseSuggestion?(false)
        LogManager.shared.log("🎤 Audio: user enabled noise reduction from suggestion (applies next recording)")
    }

    /// Dismiss the suggestion toast. When `forever` is true, never show it again.
    func dismissNoiseSuggestion(forever: Bool) {
        showNoiseSuggestion = false
        presentNoiseSuggestion?(false)
        if forever {
            noiseSuggestionDismissedForever = true
            UserDefaults.standard.set(true, forKey: Self.noiseSuggestionDismissedKey)
        }
    }

    // MARK: - Recording Lifecycle

    /// Pre-roll / warm-up window before the recording timeline begins. The capture engine (screen
    /// + mic) runs for this whole window while the writer stays "disarmed" and discards everything,
    /// then arms at the end (see RecordingManager). It serves two purposes: (1) the "Hero" start
    /// sound (peak < −50 dBFS by ~0.74s) plays and is discarded instead of being captured, and
    /// (2) the mic's voice-processing unit fully spins up during it, so the first words spoken
    /// aren't clipped. The UI timer / saved duration are measured from lastStartTime, set when the
    /// writer arms, so they're unaffected.
    private static let startSoundMaskDelay: UInt64 = 650_000_000  // 0.65s

    func startRecording() async throws {
        // Permission gate — must run BEFORE the start sound and before any capture is
        // armed. Starting a recording while a required permission is missing produced a
        // silently broken artifact (a video file with no audio track at all). Screen
        // recording is always required; the mic only when it's enabled; the camera only
        // when the face-cam is enabled. Accessibility is never a recording precondition.
        // If anything is still missing, surface the Permissions window and DO NOT start —
        // no sound, no capture, no file.
        let missing = await PermissionsManager.ensureRecordingPermissions(
            microphoneEnabled: isMicrophoneEnabled,
            cameraEnabled: isCameraEnabled
        )
        guard missing.isEmpty else {
            LogManager.shared.log(
                "🔒 Recording blocked — missing permission(s): \(missing.map(\.title).joined(separator: ", "))",
                type: .error
            )
            if let present = presentPermissionsGate {
                present(missing)
            } else if let first = missing.first {
                // No SwiftUI window host wired yet (launched straight to the menu bar):
                // fall back to activating the app and opening System Settings directly.
                NSApp.activate(ignoringOtherApps: true)
                PermissionsManager.openSystemSettings(for: first)
            }
            return
        }

        // Play start sound immediately on button click.
        SoundManager.shared.play(.start)

        // The recording engine warms up during the mask delay and only "arms" (starts keeping
        // frames) once it elapses — keeping the start sound out of the recording AND ensuring the
        // mic is already capturing when recording begins. See RecordingManager.startRecording.
        try await recordingManager.startRecording(
            microphoneEnabled: isMicrophoneEnabled,
            microphoneDeviceID: selectedMicrophoneID,
            reduceBackgroundNoise: reduceBackgroundNoise,
            recordSystemAudio: recordSystemAudio,
            videoWidth: videoResolution.width,
            videoHeight: videoResolution.height,
            fps: videoFrameRate.rawValue,
            startMaskDelay: Self.startSoundMaskDelay
        )
    }

    /// Abort recording: stops and discards the file without saving or uploading
    func abortRecording() async {
        // Nothing to merge into a file that is about to be deleted.
        guard let recording = await recordingManager.stopRecording(playSound: false, mergeSystemAudio: false) else { return }
        
        // Play abort sound
        SoundManager.shared.play(.abort)
        
        // Delete the local file immediately
        try? FileManager.default.removeItem(at: recording.fileURL)
        // The sidecar belongs to the take the user just threw away - leaving it would
        // strand a -system.m4a next to nothing.
        if let systemAudioURL = recording.systemAudioURL {
            try? FileManager.default.removeItem(at: systemAudioURL)
        }
        LogManager.shared.log("🗑️ Recording aborted and file deleted", type: .info)
    }

    func stopRecording() async {
        guard let recording = await recordingManager.stopRecording() else { return }
        let newRecording = recording

        recordings.insert(newRecording, at: 0)
        saveRecordings()

        // Process everything in the background (non-blocking)
        let recordingID = newRecording.id
        Task { await self.processRecording(id: recordingID) }
    }

    /// The writer died mid-recording: everything appended from now on would be
    /// silently dropped. Stop immediately and salvage whatever finalized into the
    /// normal upload pipeline. We do NOT auto-restart into a fresh take (see the
    /// onWriterFailed wiring in init for why). Rare now that the periodic fragment
    /// flush — the old -16341 killer — has been removed from the writer.
    private func recoverFromWriterFailure() async {
        guard recordingManager.isRecording else { return }
        if let salvaged = await recordingManager.stopRecording(playSound: false) {
            recordings.insert(salvaged, at: 0)
            saveRecordings()
            let recordingID = salvaged.id
            Task { await self.processRecording(id: recordingID) }
        }
        // Audible cue that the recording ended on its own, so the user knows to check.
        SoundManager.shared.play(.abort)
    }

    /// Background processing: init → open browser → parallel video+thumb upload →
    /// PATCH (uploaded) → AI → upload SRT → final PATCH (ready) → cleanup.
    /// Title is now pure DB metadata — the slug-keyed Dropbox folder never gets renamed.
    private func processRecording(id: UUID) async {
        LogManager.shared.log("🎬 Starting background processing for recording \(id)")

        // Use a local helper to update recording state safely
        func updateRecording(id: UUID, block: @escaping (inout Recording) -> Void) {
            DispatchQueue.main.async {
                if let index = self.recordings.firstIndex(where: { $0.id == id }) {
                    block(&self.recordings[index])
                    self.saveRecordings()
                }
            }
        }

        guard let recording = recordings.first(where: { $0.id == id }) else {
            LogManager.shared.log("⚠️ Processing: Recording \(id) not found in state", type: .info)
            return
        }
        let fileURL = recording.fileURL

        // Placeholder title used as fallback if AI naming fails
        let creationDate = recording.createdAt
        let placeholderTitle: String = {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "d MMM yyyy HH:mm"
            return "Recording · \(fmt.string(from: creationDate))"
        }()

        // Slug + folder + token captured up front; the AI step at the end
        // PATCHes the same slug.
        var slug: String?
        var uploadFolder: String?
        var videoFilename = "video.mp4"
        var transcriptFilename = "transcript.srt"
        var thumbnailFilename = "thumbnail.jpg"
        var token = ""
        var didUploadVideo = false
        var thumbnailShareURL: String? = nil

        // Step 0: Reserve a slug + Dropbox folder *before* uploading so we know
        // where to put bytes. Skipped on retry if a prior init already succeeded.
        if autoUploadEnabled && dropboxAuthManager.isSignedIn && tracerAPIClient.isSignedIn {
            updateRecording(id: id) {
                $0.uploadStatus = .uploading
                $0.uploadError = nil
            }

            token = await dropboxAuthManager.refreshTokenIfNeeded() ?? dropboxAuthManager.accessToken ?? ""
            if token.isEmpty {
                LogManager.shared.log("📤 Upload: ❌ No Dropbox token", type: .error)
                updateRecording(id: id) {
                    $0.uploadStatus = .failed
                    $0.uploadError = "No Dropbox token"
                }
                return
            }

            // Reuse a prior reservation on retry; otherwise call init.
            if let existingSlug = recording.tracerSlug, let existingFolder = recording.dropboxFolder {
                slug = existingSlug
                uploadFolder = existingFolder
                LogManager.shared.log("📤 Upload: Resuming previous reservation slug=\(existingSlug)")
            } else if let init_ = await tracerAPIClient.initVideo(recordedAt: recording.createdAt, durationEstimate: recording.duration) {
                slug = init_.slug
                uploadFolder = init_.uploadFolder
                videoFilename = init_.videoFilename
                transcriptFilename = init_.transcriptFilename
                thumbnailFilename = init_.thumbnailFilename
                let folder = init_.uploadFolder
                let videoPath = "\(folder)/\(init_.videoFilename)"
                updateRecording(id: id) {
                    $0.tracerSlug = init_.slug
                    $0.tracerURL = init_.url
                    $0.dropboxFolder = folder
                    $0.dropboxPath = videoPath
                }
                if let url = URL(string: init_.url) {
                    // Open the page right now — server already created the row in
                    // status "uploading", so the watcher polls until "ready".
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                }
                LogManager.shared.log("🌐 Tracer: ✅ Reserved slug=\(init_.slug), browser opened → \(init_.url)")
            } else {
                LogManager.shared.log("🌐 Tracer: ❌ initVideo failed — aborting upload", type: .error)
                updateRecording(id: id) {
                    $0.uploadStatus = .failed
                    $0.uploadError = "Failed to reserve slug"
                }
                return
            }

            guard let resolvedFolder = uploadFolder, let resolvedSlug = slug else {
                updateRecording(id: id) {
                    $0.uploadStatus = .failed
                    $0.uploadError = "Missing slug after init"
                }
                return
            }

            // Step 1: Pre-AI thumbnail. Detached so it runs concurrently with
            // the video upload — for big videos this is the difference between
            // a blank /v/{slug} page and one with a real preview.
            let thumbTask: Task<String?, Never> = Task.detached { [self] in
                guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
                do {
                    let jpgURL = try await ThumbnailGenerator.generateJPG(from: fileURL)
                    defer { try? FileManager.default.removeItem(at: jpgURL) }
                    let jpgData = try Data(contentsOf: jpgURL)
                    let thumbPath = "\(resolvedFolder)/\(thumbnailFilename)"
                    _ = try await self.dropboxUploadManager.uploadData(
                        jpgData,
                        dropboxPath: thumbPath,
                        mode: .overwrite,
                        accessToken: token
                    )
                    let shared = try await self.dropboxUploadManager.createSharedLink(
                        path: thumbPath,
                        accessToken: token
                    )
                    let raw = Self.toRawDropboxURL(shared)
                    await self.tracerAPIClient.updateVideo(slug: resolvedSlug, thumbnailURL: raw)
                    LogManager.shared.log("🖼️ Thumbnail: ✅ uploaded \(thumbPath)")
                    return raw
                } catch {
                    LogManager.shared.log(error: error, message: "🖼️ Thumbnail: upload failed")
                    return nil
                }
            }

            // Step 2: Upload the video to its slug-keyed canonical path.
            do {
                let videoPath = "\(resolvedFolder)/\(videoFilename)"
                LogManager.shared.log("📤 Upload: Starting video upload → \(videoPath)")
                let uploadedPath: String
                do {
                    uploadedPath = try await dropboxUploadManager.upload(
                        fileURL: fileURL,
                        dropboxPath: videoPath,
                        mode: .overwrite,
                        accessToken: token
                    )
                } catch {
                    // B1.9: a long upload can outlive the short-lived Dropbox token,
                    // so a stale-token failure would otherwise be permanent. Refresh
                    // once; only retry if we actually got a *different* token (i.e.
                    // the old one had expired) — otherwise rethrow so genuine failures
                    // still surface. NOTE: this re-uploads from the start; chunked
                    // resume with a fresh token remains a future optimization.
                    let refreshed = await dropboxAuthManager.refreshTokenIfNeeded() ?? token
                    guard refreshed != token else { throw error }
                    token = refreshed
                    LogManager.shared.log("📤 Upload: token refreshed after failure — retrying once", type: .info)
                    uploadedPath = try await dropboxUploadManager.upload(
                        fileURL: fileURL,
                        dropboxPath: videoPath,
                        mode: .overwrite,
                        accessToken: token
                    )
                }
                LogManager.shared.log("📤 Upload: ✅ Uploaded → \(uploadedPath)")

                let sharedURL = try await dropboxUploadManager.createSharedLink(
                    path: uploadedPath,
                    accessToken: token
                )
                // The URL itself is the capability: anyone holding it can watch the
                // recording, so it does not belong in a log we ask people to send us.
                LogManager.shared.log("🔗 Shared link: ✅ (\(sharedURL.count) chars)")

                let currentSize = recordings.first(where: { $0.id == id })?.fileSize
                let currentDuration = recordings.first(where: { $0.id == id })?.duration ?? recording.duration

                updateRecording(id: id) {
                    $0.dropboxPath = uploadedPath
                    $0.dropboxSharedURL = sharedURL
                    $0.uploadStatus = .uploaded
                    $0.uploadCompletedAt = Date()
                }
                didUploadVideo = true

                // Step 2.5: Tell the server the bytes have landed. AI is still
                // running so processingStatus stays "processing" until step 5.
                await tracerAPIClient.updateVideo(
                    slug: resolvedSlug,
                    dropboxPath: uploadedPath,
                    dropboxSharedURL: sharedURL,
                    fileSize: currentSize,
                    duration: currentDuration,
                    processingStatus: "processing"
                )
            } catch {
                LogManager.shared.log(error: error, message: "📤 Upload: ❌ Failed")
                updateRecording(id: id) {
                    $0.uploadStatus = .failed
                    $0.uploadError = error.localizedDescription
                }
                // Mark the row as upload_failed so the web UI can stop spinning.
                await tracerAPIClient.updateVideo(slug: resolvedSlug, processingStatus: "upload_failed")
                return
            }

            // Wait for the thumbnail task — keeps the local file alive until
            // ThumbnailGenerator finishes reading it.
            thumbnailShareURL = await thumbTask.value
            if let thumb = thumbnailShareURL {
                updateRecording(id: id) {
                    $0.thumbnailURL = thumb
                }
            }
        } else {
            // Upload preconditions not met (auto-upload off, or signed out). A
            // fresh recording is still `.notUploaded` here so nothing changes,
            // but a `retryUpload` already flipped the status to `.uploading` —
            // reset it so the row doesn't spin forever with no upload running.
            updateRecording(id: id) {
                if $0.uploadStatus == .uploading {
                    $0.uploadStatus = .failed
                    $0.uploadError = "Upload skipped — sign in to Tracer/Dropbox and enable auto-upload"
                }
            }
        }

        // Step 3: Combined Gemini call — generates SRT subtitles AND AI filename in one request.
        // Audio is locally trimmed of silence before sending (Phase A); SRT timestamps are
        // mapped back onto the original timeline so they sync with the unmodified video.
        // Outer retry: if the combined call returns both nil, wait 10s and retry once.
        // Re-read entitlements before choosing an engine. Without this the app can decide
        // to use cloud transcription on a tier the server will refuse, and find out one
        // expensive encode later.
        if tracerAPIClient.isSignedIn {
            await tracerAPIClient.refreshProfile()
        }

        LogManager.shared.log("🤖 Starting combined subtitle + naming generation...")
        var generatedSubtitles: String? = nil
        var aiName: String? = nil

        var aiUsage = GeminiUsage.zero
        var aiTotalLatencyMs = 0
        var aiTotalAttempts = 0
        var aiModel = "gemini-2.5-flash-lite"
        var aiLastError: String? = nil
        var aiSucceeded = false

        // A retry re-enters this whole function, so an upload that failed for network
        // reasons used to re-run transcription from scratch. Cheap when that meant one
        // cloud call; on-device transcription of a long recording is minutes of CPU.
        let cached = recordings.first(where: { $0.id == id })
        let cachedTranscript = (cached?.transcriptSrt?.isEmpty == false) ? cached?.transcriptSrt : nil
        // Both halves are required: the setting is what the user asked for, the entitlement is
        // what they are allowed. Read here, after the profile refresh above, so a plan change
        // takes effect on this recording rather than the next one.
        let shouldDiarize = diarizationEnabled && tracerAPIClient.entitlements.diarization

        var firstPass: NamingResult? = nil
        if let cachedTranscript {
            LogManager.shared.log("🤖 Reusing the transcript from an earlier pass (\(cachedTranscript.count) chars) — skipping transcription")
            generatedSubtitles = cachedTranscript
            aiName = cached?.aiGeneratedName
            aiSucceeded = true
        } else {
            let pass = await aiNamingService.generateSubtitlesAndName(
                for: fileURL, systemAudioURL: cached?.systemAudioURL, diarize: shouldDiarize
            )
            firstPass = pass
            generatedSubtitles = pass.srt
            aiName = pass.name
            aiUsage.add(pass.usage)
            aiTotalLatencyMs += pass.latencyMs
            aiTotalAttempts += pass.attempts
            aiModel = pass.model
            aiLastError = pass.errorCode
            aiSucceeded = pass.success
        }

        // Only retry when a retry could plausibly help. `fatal` marks deterministic failures
        // (oversized request, signed out, bad request) and chunked runs that already did their
        // own internal retry wave — re-running those costs a full re-encode plus N more calls
        // to fail identically. Before this gate, a 413 burned six doomed POSTs and ~45s.
        if let firstPass, generatedSubtitles == nil, aiName == nil, !firstPass.fatal {
            LogManager.shared.log("🤖 Combined: ⚠️ First pass returned nothing — waiting 10s before second pass...", type: .error)
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            let secondPass = await aiNamingService.generateSubtitlesAndName(
                for: fileURL, systemAudioURL: cached?.systemAudioURL, diarize: shouldDiarize
            )
            generatedSubtitles = secondPass.srt
            aiName = secondPass.name
            aiUsage.add(secondPass.usage)
            aiTotalLatencyMs += secondPass.latencyMs
            aiTotalAttempts += secondPass.attempts
            aiModel = secondPass.model
            aiLastError = secondPass.errorCode ?? aiLastError
            aiSucceeded = aiSucceeded || secondPass.success
            if generatedSubtitles == nil && aiName == nil {
                LogManager.shared.log("🤖 Combined: ❌ Both passes failed — proceeding with placeholder name and no transcript", type: .error)
            } else {
                LogManager.shared.log("🤖 Combined: ✅ Second pass succeeded — name=\"\(aiName ?? "nil")\", srtLen=\(generatedSubtitles?.count ?? 0)")
            }
        } else {
            LogManager.shared.log("🤖 Combined: ✅ First pass — name=\"\(aiName ?? "nil")\", srtLen=\(generatedSubtitles?.count ?? 0)")
        }

        // What the labels in this transcript assumed, so the Recordings list shows the answer
        // this recording was given rather than whatever the setting says by then.
        let speakersUsed: ExpectedSpeakers? = shouldDiarize ? expectedSpeakers : nil
        if let generatedSubtitles, !generatedSubtitles.isEmpty {
            updateRecording(id: id) {
                $0.transcriptSrt = generatedSubtitles
                $0.transcriptEngine = aiModel
                if let speakersUsed { $0.expectedSpeakers = speakersUsed }
            }
        }

        let aiUsagePayload = TracerAPIClient.AIUsagePayload(
            kind: "naming",
            model: aiModel,
            promptTokens: aiUsage.promptTokens,
            outputTokens: aiUsage.outputTokens,
            totalTokens: aiUsage.totalTokens,
            modalityBreakdown: aiUsage.modalityBreakdown.map { ($0.modality, $0.tokenCount) },
            latencyMs: aiTotalLatencyMs,
            attempts: aiTotalAttempts,
            success: aiSucceeded,
            errorCode: aiLastError
        )
        LogManager.shared.log("🤖 AI usage total: prompt=\(aiUsage.promptTokens), out=\(aiUsage.outputTokens), attempts=\(aiTotalAttempts), success=\(aiSucceeded)")

        if let aiNameBase = aiName {
            updateRecording(id: id) {
                $0.aiGeneratedName = aiNameBase
            }
            LogManager.shared.log("🤖 AI Naming: ✅ Named: \"\(aiNameBase)\"")
        }

        // Step 4: Upload transcript.srt to Dropbox so the user has a complete
        // copy outside our DB (full disaster-recovery from Dropbox).
        if let srt = generatedSubtitles, !srt.isEmpty,
           let folder = uploadFolder, !token.isEmpty {
            do {
                let srtPath = "\(folder)/\(transcriptFilename)"
                _ = try await dropboxUploadManager.uploadText(srt, dropboxPath: srtPath, accessToken: token)
                LogManager.shared.log("📝 Transcript: ✅ uploaded \(srtPath)")
            } catch {
                LogManager.shared.log(error: error, message: "📝 Transcript: upload failed (continuing)")
            }
        }

        // Step 5: Final PATCH — title + transcript + status="ready".
        // No Dropbox renames: the slug folder is the stable identifier.
        if let resolvedSlug = slug {
            let finalTitle = aiName ?? placeholderTitle
            await tracerAPIClient.updateVideo(
                slug: resolvedSlug,
                title: finalTitle,
                transcriptSrt: generatedSubtitles,
                thumbnailURL: thumbnailShareURL,
                processingStatus: "ready",
                aiUsage: aiUsagePayload
            )
            LogManager.shared.log("🌐 Tracer: ✅ Final PATCH — title: \"\(finalTitle)\"")
        }

        // Step 5.5: keep the audio a later re-run of speaker separation will need. Must happen
        // before Step 6 deletes the video, and only pays off when there is a transcript to
        // re-label in the first place.
        if let srt = generatedSubtitles, !srt.isEmpty {
            let kept = await preserveDiarizationAudio(
                id: id,
                videoURL: fileURL,
                systemAudioURL: cached?.systemAudioURL,
                alreadyInDropboxAt: recordings.first(where: { $0.id == id })?.diarizationMicPath,
                folder: uploadFolder,
                token: token
            )
            if kept.mic != nil || kept.system != nil {
                updateRecording(id: id) {
                    $0.diarizationMicPath = kept.mic ?? $0.diarizationMicPath
                    $0.diarizationSystemPath = kept.system ?? $0.diarizationSystemPath
                }
            }
        }

        // Step 6: Delete local file after everything is done
        if didUploadVideo {
            try? FileManager.default.removeItem(at: fileURL)
            LogManager.shared.log("🗑️ Local file deleted: \(fileURL.lastPathComponent)")
            // The sidecar was kept alive only for this pipeline, and nothing cleaned it up
            // before: 128 kbps stereo of a call is ~58 MB an hour piling up next to a video
            // that no longer exists. Whatever a re-run needs from it now lives in the
            // diarization cache at a quarter of the size.
            if let sidecarURL = cached?.systemAudioURL {
                try? FileManager.default.removeItem(at: sidecarURL)
                updateRecording(id: id) { $0.systemAudioURL = nil }
                LogManager.shared.log("🗑️ System audio sidecar deleted: \(sidecarURL.lastPathComponent)")
            }
            await reloadRecordingsFromTracer()
        }
    }

    // MARK: - Speaker separation, after the fact

    /// Keeps this recording's audio for a future re-run and mirrors it into Dropbox.
    ///
    /// The mic track is extracted here rather than borrowed from the transcription engine that
    /// just used it: each engine builds its own copy inside its own `defer`, and reaching into
    /// that would tie every engine to a cache none of them care about. The extra pass is one
    /// read of the audio track, seconds even on an hour-long recording.
    ///
    /// Gated on the entitlement rather than on the `diarizationEnabled` toggle. Somebody whose
    /// plan includes separation but who had it switched off is exactly the person who will
    /// switch it on after reading a transcript, and an empty cache would answer them with
    /// "no audio" for every recording they already made.
    ///
    /// - Returns: the Dropbox paths of the durable copies, when they got there.
    private func preserveDiarizationAudio(
        id: UUID,
        videoURL: URL,
        systemAudioURL: URL?,
        alreadyInDropboxAt: String?,
        folder: String?,
        token: String
    ) async -> (mic: String?, system: String?) {
        guard tracerAPIClient.entitlements.diarization else { return (nil, nil) }

        let cache = DiarizationAudioCache.shared
        // A retry re-enters this whole function, and nothing about the audio changes between
        // passes. Re-encoding and re-uploading 15 MB an hour to land on the same bytes is a
        // cost a failed upload should not keep paying.
        if cache.hasMicAudio(for: id), alreadyInDropboxAt != nil {
            return (nil, nil)
        }
        guard let extracted = await AudioPreparation.extractCompressedAudio(from: videoURL),
              let micURL = cache.install(extracted, as: .mic, for: id) else {
            LogManager.shared.log("🎛️ Diarization cache: ❌ could not keep the mic track - re-running separation later will need Dropbox", type: .error)
            return (nil, nil)
        }
        var systemURL: URL? = nil
        if let systemAudioURL {
            systemURL = await cache.storeSystemAudio(from: systemAudioURL, for: id)
        }
        cache.evict()
        LogManager.shared.log("🎛️ Diarization cache: kept \(systemURL == nil ? "mic" : "mic + system") audio, cache now \(ByteCountFormatter.string(fromByteCount: Int64(cache.totalBytes()), countStyle: .file))")

        guard let folder, !token.isEmpty else { return (nil, nil) }
        var micPath: String? = nil
        var systemPath: String? = nil
        do {
            micPath = try await dropboxUploadManager.upload(
                fileURL: micURL,
                dropboxPath: "\(folder)/\(DiarizationAudioCache.Kind.mic.filename)",
                mode: .overwrite,
                accessToken: token
            )
            if let systemURL {
                systemPath = try await dropboxUploadManager.upload(
                    fileURL: systemURL,
                    dropboxPath: "\(folder)/\(DiarizationAudioCache.Kind.system.filename)",
                    mode: .overwrite,
                    accessToken: token
                )
            }
            LogManager.shared.log("🎛️ Diarization cache: ✅ durable copy in Dropbox → \(folder)")
        } catch {
            // A missing durable copy costs a re-run only after the local cache is gone, so it
            // is not worth failing the recording over.
            LogManager.shared.log(error: error, message: "🎛️ Diarization cache: Dropbox copy failed (continuing)")
        }
        return (micPath, systemPath)
    }

    /// Re-runs speaker separation over a finished transcript with a new headcount.
    ///
    /// Only the labels change: the cues, their text and their timings are the ones the engine
    /// produced, parsed straight back out of the stored transcript. Every failure path leaves
    /// the transcript exactly as it was and says why in `speakerReapplyErrors`, because a
    /// correction that quietly destroys a good transcript is worse than a wrong label.
    @MainActor
    func reapplySpeakers(recordingID: UUID, expected: ExpectedSpeakers) async {
        guard !reapplyingSpeakers.contains(recordingID) else { return }
        guard let recording = recordings.first(where: { $0.id == recordingID }) else { return }
        guard tracerAPIClient.entitlements.diarization else {
            speakerReapplyErrors[recordingID] = "Speaker separation is not part of your plan."
            return
        }
        guard let srt = recording.transcriptSrt, !srt.isEmpty else {
            speakerReapplyErrors[recordingID] = "This recording has no transcript to re-label."
            return
        }

        reapplyingSpeakers.insert(recordingID)
        speakerReapplyErrors[recordingID] = nil
        defer { reapplyingSpeakers.remove(recordingID) }

        // Strip first, always. The labels live in the cue text as a "[Speaker 1] " prefix, so
        // re-labelling text that still carries the old prefix stacks them.
        let cues = Self.strippingSpeakerPrefixes(from: SrtCodec.parseAndRepairSrt(srt))
        guard !cues.isEmpty else {
            speakerReapplyErrors[recordingID] = "This transcript could not be read back."
            return
        }

        var relabelled = cues
        if expected == .justMe {
            // One person total is an answer, not a clustering problem: the right transcript is
            // the one with no speaker chips at all, and it needs no audio and no Core ML.
            LogManager.shared.log("🎛️ Diarization: \(recordingID) marked as one voice - dropping speaker labels")
        } else {
            let audio = await diarizationAudio(for: recording)
            guard case .ready(let micURL, let systemURL) = audio else {
                if case .missing(let reason) = audio { speakerReapplyErrors[recordingID] = reason }
                return
            }
            relabelled = await SpeakerSeparation.label(
                cues: cues,
                micAudioURL: micURL,
                systemAudioURL: systemURL,
                recordingDuration: recording.duration,
                expected: expected
            )
            // Separation hands back what it was given on every unhappy path - one voice found,
            // a model that would not load, the deadline. None of those is a reason to publish
            // a transcript stripped of the labels it already had.
            guard relabelled.contains(where: { $0.speaker != nil }) else {
                speakerReapplyErrors[recordingID] = "Could not tell the voices apart this time. The transcript is unchanged."
                return
            }
        }

        guard let rebuilt = SrtCodec.serializeSrt(relabelled) else {
            speakerReapplyErrors[recordingID] = "Could not rebuild the transcript. Nothing was changed."
            return
        }

        if let index = recordings.firstIndex(where: { $0.id == recordingID }) {
            recordings[index].transcriptSrt = rebuilt
            recordings[index].expectedSpeakers = expected
            saveRecordings()
        }

        if let slug = recording.tracerSlug {
            await tracerAPIClient.updateVideo(slug: slug, transcriptSrt: rebuilt)
            LogManager.shared.log("🎛️ Diarization: ✅ re-labelled \(slug) as \(expected.displayName)")
        }

        // Keep Dropbox's copy of the transcript in step with the one on the site, so the
        // recovery copy is not quietly a version behind.
        if let folder = recording.dropboxFolder {
            let token = await dropboxAuthManager.refreshTokenIfNeeded() ?? dropboxAuthManager.accessToken ?? ""
            if !token.isEmpty {
                do {
                    _ = try await dropboxUploadManager.uploadText(
                        rebuilt, dropboxPath: "\(folder)/transcript.srt", accessToken: token
                    )
                } catch {
                    LogManager.shared.log(error: error, message: "📝 Transcript: re-upload after re-labelling failed (continuing)")
                }
            }
        }
    }

    /// Where a re-run gets its audio: the local cache first, Dropbox when the cache has been
    /// evicted or this Mac has never seen the recording.
    private enum DiarizationAudioLookup {
        case ready(mic: URL, system: URL?)
        case missing(String)
    }

    @MainActor
    private func diarizationAudio(for recording: Recording) async -> DiarizationAudioLookup {
        let cache = DiarizationAudioCache.shared
        if let mic = cache.existingURL(.mic, for: recording.id) {
            return .ready(mic: mic, system: cache.existingURL(.system, for: recording.id))
        }

        guard let micPath = recording.diarizationMicPath else {
            return .missing("The audio for this recording is no longer available, so the speakers cannot be worked out again.")
        }
        let token = await dropboxAuthManager.refreshTokenIfNeeded() ?? dropboxAuthManager.accessToken ?? ""
        guard !token.isEmpty else {
            return .missing("Connect Dropbox to fetch this recording's audio back.")
        }

        LogManager.shared.log("🎛️ Diarization cache: nothing local for \(recording.id) - fetching the audio back from Dropbox")
        do {
            try await dropboxUploadManager.download(
                path: micPath, to: cache.url(.mic, for: recording.id), accessToken: token
            )
        } catch {
            LogManager.shared.log(error: error, message: "🎛️ Diarization cache: Dropbox fetch failed")
            return .missing("Could not fetch this recording's audio from Dropbox.")
        }

        var systemURL: URL? = nil
        if let systemPath = recording.diarizationSystemPath {
            do {
                try await dropboxUploadManager.download(
                    path: systemPath, to: cache.url(.system, for: recording.id), accessToken: token
                )
                systemURL = cache.existingURL(.system, for: recording.id)
            } catch {
                // The mic track alone still separates, just less well. Worth continuing rather
                // than refusing the whole re-run.
                LogManager.shared.log(error: error, message: "🎛️ Diarization cache: system track fetch failed (continuing on the mic track)")
            }
        }
        cache.evict()

        guard let micURL = cache.existingURL(.mic, for: recording.id) else {
            return .missing("Could not fetch this recording's audio from Dropbox.")
        }
        return .ready(mic: micURL, system: systemURL)
    }

    /// Removes the `[Name] ` prefix `SrtCodec.serializeSrt` writes onto a labelled cue, so a
    /// re-labelled transcript carries one prefix rather than one per run. Loops because a
    /// transcript that already stacked them has to come back clean, and keeps the original text
    /// when stripping would leave a cue with nothing in it.
    static func strippingSpeakerPrefixes(from cues: [SrtSegment]) -> [SrtSegment] {
        let prefix = #"^\[[^\]]{1,40}\]\s+"#
        return cues.map { cue in
            var text = cue.text
            while let range = text.range(of: prefix, options: .regularExpression) {
                let stripped = String(text[range.upperBound...])
                if stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
                text = stripped
            }
            return SrtSegment(start: cue.start, end: cue.end, text: text, speaker: nil)
        }
    }

    /// Converts a Dropbox shared URL (`www.dropbox.com/s/...?dl=0`) into a URL that renders
    /// directly in an <img> tag by forcing `raw=1`.
    static func toRawDropboxURL(_ sharedURL: String) -> String {
        guard var components = URLComponents(string: sharedURL) else { return sharedURL }
        var items = (components.queryItems ?? []).filter { $0.name != "dl" && $0.name != "raw" }
        items.append(URLQueryItem(name: "raw", value: "1"))
        components.queryItems = items
        return components.string ?? sharedURL
    }

    // MARK: - Library refresh entry point
    //
    // The library is now sourced entirely from our DB (`tracer.nocorny.com`).
    // This used to call Dropbox listFolder/sharedLinks/getFileDuration on every
    // refresh — now it's a single incremental call to /api/videos?since=…
    // backed by the videos.updated_at cursor.

    @MainActor
    func syncDropboxState() async {
        await reloadRecordingsFromTracer()
    }

    // MARK: - Persistence

    private func saveRecordings() {
        if let data = try? JSONEncoder().encode(recordings) {
            UserDefaults.standard.set(data, forKey: recordingsKey)
        }
    }

    private func loadRecordings() {
        guard let data = UserDefaults.standard.data(forKey: recordingsKey),
              let decoded = try? JSONDecoder().decode([Recording].self, from: data) else { return }
        // Any recording still marked .uploading is a leftover from a session that was
        // killed mid-upload — there is no in-flight task for it now, so it would spin
        // forever. Reconcile to .failed so the UI offers a retry instead.
        recordings = decoded.map { rec in
            guard rec.uploadStatus == .uploading else { return rec }
            var r = rec
            r.uploadStatus = .failed
            r.uploadError = "Upload interrupted — tap to retry"
            return r
        }
    }

    // MARK: - History Management

    func clearHistory() {
        recordings.removeAll()
        saveRecordings()
    }

    func deleteRecording(_ recording: Recording) async {
        // 1. Server is the source of truth: ask our backend to soft-delete the
        //    DB row and remove the Dropbox file. The app never talks to Dropbox
        //    directly for deletion anymore.
        if let slug = recording.tracerSlug, tracerAPIClient.isSignedIn {
            let ok = await tracerAPIClient.deleteVideo(slug: slug)
            LogManager.shared.log(ok ? "🗑️ Tracer: deleted \(slug)" : "❌ Tracer: delete \(slug) failed",
                                  type: ok ? .info : .error)
            guard ok else {
                // Server delete failed — the video still lives on the server and in
                // Dropbox. Keep the local entry visible (don't orphan the file
                // invisibly) and surface the failure so the user can retry.
                await MainActor.run {
                    if let idx = self.recordings.firstIndex(where: { $0.id == recording.id }) {
                        self.recordings[idx].uploadError = "Delete failed — still on server, tap to retry"
                    }
                }
                return
            }
        }

        // 2. Delete local file if it still exists (in-flight upload, etc.)
        if FileManager.default.fileExists(atPath: recording.fileURL.path) {
            try? FileManager.default.removeItem(at: recording.fileURL)
        }
        // Nothing left to re-label, so the audio kept for that is now just disk.
        DiarizationAudioCache.shared.remove(for: recording.id)

        // 3. Drop from local state immediately so UI updates without a re-sync
        DispatchQueue.main.async {
            self.recordings.removeAll { $0.id == recording.id }
            self.saveRecordings()
        }

        // 4. Refresh usage counters from our DB (cheap — same call as a list refresh)
        await reloadRecordingsFromTracer()
    }

    // MARK: - Retry Upload

    /// Retries a failed upload for a recording that still has its local file
    func retryUpload(_ recording: Recording) async {
        guard recording.uploadStatus == .failed else { return }
        guard FileManager.default.fileExists(atPath: recording.fileURL.path) else {
            print("📤 Retry: Local file no longer exists for \(recording.displayName)")
            return
        }
        guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else { return }

        LogManager.shared.log("🔄 Retry: Retrying previous upload for \(recording.displayName)", type: .info)
        recordings[index].uploadStatus = .uploading
        saveRecordings()

        let recordingID = recording.id
        Task { await self.processRecording(id: recordingID) }
    }

    // MARK: - Open Dropbox Folder

    func openDropboxWebFolder() {
        if let url = URL(string: "https://www.dropbox.com/home/Apps/NoCorny%20Tracer") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Open Tracer Dashboard

    func openTracerDashboard() {
        if let url = URL(string: "https://tracer.nocorny.com/dashboard") {
            NSWorkspace.shared.open(url)
        }
    }

    func openTracerSettings() {
        if let url = URL(string: "https://tracer.nocorny.com/settings") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Tracer → Dropbox sync

    /// Fetches the Dropbox access token that Tracer issues for the signed-in user,
    /// and activates proxied mode in the DropboxAuthManager. Called on launch,
    /// on app activation, and from a 60s heartbeat — so Disconnect/Connect on
    /// the web propagates to the macOS app without restarting it.
    @MainActor
    func syncDropboxFromTracer() async {
        guard tracerAPIClient.isSignedIn else { return }
        let wasSignedIn = dropboxAuthManager.isSignedIn
        let isInitialSync = !hasCompletedInitialDropboxSync

        switch await tracerAPIClient.fetchDropboxAccessToken() {
        case .transientFailure:
            // We could not reach or understand the server (offline, timeout, 5xx,
            // unparseable body). This is NOT a disconnect. Treating it as one used
            // to wipe the entire local library on a mere Wi-Fi blip. Leave all
            // local state untouched and try again on the next tick.
            LogManager.shared.log("🌐 Tracer: Dropbox status unreachable — keeping local state", type: .info)
            return

        case .authoritativeNegative:
            // Server definitively says Dropbox is gone. The web hard-deletes video
            // rows on disconnect, so the incremental `?since=` sync would never
            // notice them disappear — we have to wipe the local cache ourselves.
            // Includes the launch-after-disconnect case: in-memory `isSignedIn`
            // is false fresh out of init(), but `recordings`/quota/cursor were
            // restored from disk and need cleaning.
            dropboxAuthManager.clearProxiedState()
            if hasLocalDropboxLibraryState() {
                resetTracerLibraryState()
            }
            hasCompletedInitialDropboxSync = true
            return

        case .success(let tokenResult):
            await dropboxAuthManager.applyProxiedToken(accessToken: tokenResult.token,
                                                       expiresAt: tokenResult.expiresAt)
            hasCompletedInitialDropboxSync = true

            // Fresh connection (or account switch) detected mid-session — pull the
            // new account's library so the Recordings tab populates immediately,
            // and surface the success sheet. Suppress on the initial launch sync,
            // where wasSignedIn is always false simply because DropboxAuthManager
            // doesn't persist isSignedIn across launches. We gate by a session
            // flag (not a parameter) because launch fires concurrent syncs from
            // both the init Task and didBecomeActive — either can win the race.
            if !wasSignedIn && !isInitialSync {
                dropboxAuthManager.showConnectionConfirmation = true
                await reloadRecordingsFromTracer()
            }
        }
    }

    private func hasLocalDropboxLibraryState() -> Bool {
        if !recordings.isEmpty { return true }
        if dropboxAllocatedSpace > 0 || dropboxUsedSpace > 0 { return true }
        if UserDefaults.standard.object(forKey: Self.lastTracerSyncAtKey) != nil {
            return true
        }
        return false
    }

    /// Incremental sync from our DB. The server uses `videos.updated_at` as the
    /// cursor; we persist the last server time we saw so subsequent calls only
    /// fetch what changed (typically zero rows). Storage usage comes back in
    /// the same envelope so we never have to call Dropbox for quota at runtime.
    @MainActor
    func reloadRecordingsFromTracer() async {
        guard tracerAPIClient.isSignedIn else { return }

        isSyncingDropbox = true
        defer { isSyncingDropbox = false }

        let lastSync = UserDefaults.standard.object(forKey: Self.lastTracerSyncAtKey) as? Date
        guard let envelope = await tracerAPIClient.listVideos(since: lastSync) else { return }

        var working = recordings

        for v in envelope.videos {
            if let idx = working.firstIndex(where: { $0.tracerSlug == v.slug }) {
                if v.isDeleted == true {
                    working.remove(at: idx)
                    continue
                }
                // Don't clobber a recording that is still uploading locally: the
                // server row exists (created at init in "uploading") but may not
                // yet carry the final path / shared URL / title, and overwriting
                // would null out fields the client just set mid-upload.
                if working[idx].uploadStatus == .uploading {
                    continue
                }
                // Preserve fields the server doesn't know about (local fileURL, the
                // local UUID). Nil-coalesce so a transiently-empty server value
                // never erases good local data. fileSize is guarded against the
                // UInt64(Int64) trap on a negative value.
                working[idx].dropboxPath = v.dropboxPath
                working[idx].dropboxSharedURL = v.dropboxSharedUrl ?? working[idx].dropboxSharedURL
                working[idx].duration = v.duration ?? working[idx].duration
                working[idx].fileSize = v.fileSize.flatMap { $0 >= 0 ? UInt64($0) : nil } ?? working[idx].fileSize
                working[idx].thumbnailURL = v.thumbnailUrl ?? working[idx].thumbnailURL
                working[idx].aiGeneratedName = v.title
                working[idx].tracerURL = "https://tracer.nocorny.com/v/\(v.slug)"
            } else if v.isDeleted != true {
                let created = v.recordedAt ?? v.createdAt ?? Date()
                let fakeURL = URL(fileURLWithPath: "/tmp/\(v.slug).mp4")
                var rec = Recording(
                    id: UUID(),
                    fileURL: fakeURL,
                    createdAt: created,
                    duration: v.duration ?? 0,
                    aiGeneratedName: v.title,
                    uploadStatus: .uploaded
                )
                rec.dropboxPath = v.dropboxPath
                rec.dropboxSharedURL = v.dropboxSharedUrl
                rec.tracerSlug = v.slug
                rec.tracerURL = "https://tracer.nocorny.com/v/\(v.slug)"
                rec.thumbnailURL = v.thumbnailUrl
                rec.fileSize = v.fileSize.flatMap { $0 >= 0 ? UInt64($0) : nil }
                working.append(rec)
            }
        }

        working.sort { $0.createdAt > $1.createdAt }
        recordings = working
        saveRecordings()

        if let used = envelope.usage?.usedBytes, used >= 0 {
            dropboxUsedSpace = UInt64(used)
            UserDefaults.standard.set(Double(used), forKey: Self.dropboxUsedSpaceKey)
        }
        if let allocated = envelope.usage?.allocatedBytes, allocated > 0 {
            dropboxAllocatedSpace = UInt64(allocated)
            UserDefaults.standard.set(Double(allocated), forKey: Self.dropboxAllocatedSpaceKey)
        }

        if let serverTime = envelope.serverTime {
            UserDefaults.standard.set(serverTime, forKey: Self.lastTracerSyncAtKey)
        }
    }

    /// Clears local library state. Call from sign-out so the next account that
    /// signs in does a fresh full sync instead of inheriting another user's rows.
    @MainActor
    func resetTracerLibraryState() {
        recordings.removeAll()
        saveRecordings()
        dropboxUsedSpace = 0
        dropboxAllocatedSpace = 0
        UserDefaults.standard.removeObject(forKey: Self.dropboxUsedSpaceKey)
        UserDefaults.standard.removeObject(forKey: Self.dropboxAllocatedSpaceKey)
        UserDefaults.standard.removeObject(forKey: Self.lastTracerSyncAtKey)
    }

    // MARK: - Open Recordings Folder

    func openRecordingsFolder() {
        NSWorkspace.shared.open(Self.recordingsDirectory)
    }

    // MARK: - Recordings Directory

    static var recordingsDirectory: URL {
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NoCornyTracer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
