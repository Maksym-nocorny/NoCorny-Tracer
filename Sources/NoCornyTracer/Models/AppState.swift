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
        )
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
    var dropboxUsedSpace: UInt64 = 0
    var dropboxAllocatedSpace: UInt64 = 0
    var isSyncingDropbox: Bool = false

    var selectedMicrophoneID: String?
    var isMicrophoneEnabled: Bool = true
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

    /// Set to true on first launch to show a dialog asking about launch at login
    var showLaunchAtLoginPrompt = false

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

        // Wire up proxied Dropbox: the DropboxAuthManager asks Tracer for a fresh
        // access token, and "Connect Dropbox" opens the web settings page.
        dropboxAuthManager.fetchProxiedToken = { [weak self] in
            guard let self = self,
                  let result = await self.tracerAPIClient.fetchDropboxAccessToken(),
                  result.connected, let token = result.accessToken else { return nil }
            let expiresAt = result.expiresAt.flatMap { ISO8601DateFormatter().date(from: $0) }
            return (token, expiresAt)
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

    // MARK: - Recording Lifecycle

    func startRecording() async throws {
        // Play start sound immediately on button click
        SoundManager.shared.play(.start)

        // Wait 1.0 second to allow UI/popovers to hide AND sound to finish before recording starts
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        
        try await recordingManager.startRecording(
            microphoneEnabled: isMicrophoneEnabled,
            microphoneDeviceID: selectedMicrophoneID,
            videoWidth: videoResolution.width,
            videoHeight: videoResolution.height,
            fps: videoFrameRate.rawValue
        )
    }

    /// Abort recording: stops and discards the file without saving or uploading
    func abortRecording() async {
        guard let recording = await recordingManager.stopRecording(playSound: false) else { return }
        
        // Play abort sound
        SoundManager.shared.play(.abort)
        
        // Delete the local file immediately
        try? FileManager.default.removeItem(at: recording.fileURL)
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
                let uploadedPath = try await dropboxUploadManager.upload(
                    fileURL: fileURL,
                    dropboxPath: videoPath,
                    mode: .overwrite,
                    accessToken: token
                )
                LogManager.shared.log("📤 Upload: ✅ Uploaded → \(uploadedPath)")

                let sharedURL = try await dropboxUploadManager.createSharedLink(
                    path: uploadedPath,
                    accessToken: token
                )
                LogManager.shared.log("🔗 Shared link: ✅ \(sharedURL)")

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
        }

        // Step 3: Combined Gemini call — generates SRT subtitles AND AI filename in one request.
        // Audio is locally trimmed of silence before sending (Phase A); SRT timestamps are
        // mapped back onto the original timeline so they sync with the unmodified video.
        // Outer retry: if the combined call returns both nil, wait 10s and retry once.
        LogManager.shared.log("🤖 Starting combined subtitle + naming generation...")
        var generatedSubtitles: String? = nil
        var aiName: String? = nil

        var aiUsage = GeminiUsage.zero
        var aiTotalLatencyMs = 0
        var aiTotalAttempts = 0
        var aiModel = "gemini-2.5-flash-lite"
        var aiLastError: String? = nil
        var aiSucceeded = false

        let firstPass = await aiNamingService.generateSubtitlesAndName(for: fileURL)
        generatedSubtitles = firstPass.srt
        aiName = firstPass.name
        aiUsage.add(firstPass.usage)
        aiTotalLatencyMs += firstPass.latencyMs
        aiTotalAttempts += firstPass.attempts
        aiModel = firstPass.model
        aiLastError = firstPass.errorCode
        aiSucceeded = firstPass.success

        if generatedSubtitles == nil && aiName == nil {
            LogManager.shared.log("🤖 Combined: ⚠️ First pass returned nothing — waiting 10s before second pass...", type: .error)
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            let secondPass = await aiNamingService.generateSubtitlesAndName(for: fileURL)
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

        // Step 6: Delete local file after everything is done
        if didUploadVideo {
            try? FileManager.default.removeItem(at: fileURL)
            LogManager.shared.log("🗑️ Local file deleted: \(fileURL.lastPathComponent)")
            await reloadRecordingsFromTracer()
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
        recordings = decoded
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
        }

        // 2. Delete local file if it still exists (in-flight upload, etc.)
        if FileManager.default.fileExists(atPath: recording.fileURL.path) {
            try? FileManager.default.removeItem(at: recording.fileURL)
        }

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

        guard let result = await tracerAPIClient.fetchDropboxAccessToken(),
              result.connected, let token = result.accessToken else {
            dropboxAuthManager.clearProxiedState()
            // Server says Dropbox is gone. The web hard-deletes video rows on
            // disconnect, so the incremental `?since=` sync would never notice
            // them disappear — we have to wipe the local cache ourselves.
            // Includes the launch-after-disconnect case: in-memory `isSignedIn`
            // is false fresh out of init(), but `recordings`/quota/cursor were
            // restored from disk and need cleaning.
            if hasLocalDropboxLibraryState() {
                resetTracerLibraryState()
            }
            hasCompletedInitialDropboxSync = true
            return
        }
        let expiresAt = result.expiresAt.flatMap { ISO8601DateFormatter().date(from: $0) }
        await dropboxAuthManager.applyProxiedToken(accessToken: token, expiresAt: expiresAt)
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
                // Preserve fields the server doesn't know about (in-flight status,
                // local fileURL, the local UUID).
                working[idx].dropboxPath = v.dropboxPath
                working[idx].dropboxSharedURL = v.dropboxSharedUrl
                working[idx].duration = v.duration ?? working[idx].duration
                working[idx].fileSize = v.fileSize.map { UInt64($0) } ?? working[idx].fileSize
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
                rec.fileSize = v.fileSize.map { UInt64($0) }
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
