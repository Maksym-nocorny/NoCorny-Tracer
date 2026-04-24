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
    let aiNamingService = AINamingService()
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

    /// Set to true on first launch to show a dialog asking about launch at login
    var showLaunchAtLoginPrompt = false

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

        // If the user is already signed in to Tracer at launch, try to pick up
        // their Dropbox connection from the server immediately.
        if tracerAPIClient.isSignedIn {
            Task { await self.syncDropboxFromTracer() }
            Task { await self.reloadRecordingsFromTracer() }
        }

        // Apply theme appearance after app finishes launching (NSApp is nil during init)
        DispatchQueue.main.async { [weak self] in
            self?.updateAppAppearance()
        }
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

    /// Background processing: upload → shared link → subtitles → AI name → rename → cleanup
    /// Background processing: upload → shared link → subtitles → AI name → rename → cleanup
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

        // Placeholder title used for Phase 1 registration and as fallback if AI naming fails
        let creationDate = recording.createdAt
        let placeholderTitle: String = {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "d MMM yyyy HH:mm"
            return "Recording · \(fmt.string(from: creationDate))"
        }()

        // Step 1: Upload to Dropbox immediately with default timestamp name
        var dropboxPath: String?
        var token = ""
        // Tracks the Phase 1 registration result so Phase 2 can PATCH it later
        var phase1Result: TracerAPIClient.RegisteredVideo?

        if autoUploadEnabled && dropboxAuthManager.isSignedIn && tracerAPIClient.isSignedIn {
            updateRecording(id: id) {
                $0.uploadStatus = .uploading
                $0.uploadError = nil
            }

            do {
                token = await dropboxAuthManager.refreshTokenIfNeeded() ?? dropboxAuthManager.accessToken ?? ""

                if token.isEmpty {
                    throw DropboxUploadManager.DropboxError.invalidToken
                }

                let currentName = recording.displayName
                LogManager.shared.log("📤 Upload: Starting upload for \"\(currentName)\"")

                let uploadedPath = try await dropboxUploadManager.upload(
                    fileURL: fileURL,
                    fileName: currentName + ".mp4",
                    accessToken: token
                )

                dropboxPath = uploadedPath
                updateRecording(id: id) {
                    $0.dropboxPath = uploadedPath
                    $0.uploadStatus = .uploaded
                    $0.uploadCompletedAt = Date()
                }
                LogManager.shared.log("📤 Upload: ✅ Uploaded to Dropbox: \(uploadedPath)")

                // Create shared link immediately after upload
                let sharedURL = try await dropboxUploadManager.createSharedLink(
                    path: uploadedPath,
                    accessToken: token
                )
                updateRecording(id: id) {
                    $0.dropboxSharedURL = sharedURL
                }
                LogManager.shared.log("🔗 Shared link: ✅ \(sharedURL)")

                // Phase 1: register immediately with a placeholder title so the browser
                // can open right now — 3-6 minutes before Gemini finishes.
                if let current = recordings.first(where: { $0.id == id }) {
                    phase1Result = await tracerAPIClient.registerVideo(
                        title: placeholderTitle,
                        dropboxPath: uploadedPath,
                        dropboxSharedURL: sharedURL,
                        duration: current.duration,
                        fileSize: current.fileSize,
                        recordedAt: current.createdAt,
                        processingStatus: "processing"
                    )
                    if let phase1 = phase1Result {
                        updateRecording(id: id) {
                            $0.tracerSlug = phase1.slug
                            $0.tracerURL = phase1.url
                        }
                        if let url = URL(string: phase1.url) {
                            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                        }
                        LogManager.shared.log("🌐 Tracer: Phase 1 registered, browser opened → \(phase1.url)")
                    }
                }

            } catch {
                LogManager.shared.log(error: error, message: "📤 Upload: ❌ Failed")
                updateRecording(id: id) {
                    $0.uploadStatus = .failed
                    $0.uploadError = error.localizedDescription
                }
                // Stop processing if upload failed
                return
            }
        }

        // Step 2: Generate subtitles (used for AI naming, not uploaded)
        LogManager.shared.log("🤖 Starting subtitle generation...")
        var generatedSubtitles: String? = nil

        if let subtitles = await aiNamingService.generateSubtitles(for: fileURL) {
            generatedSubtitles = subtitles
            LogManager.shared.log("🤖 Subtitles: ✅ Generated content length: \(subtitles.count)")
        }

        // Step 3: AI Naming (using frames + subtitles)
        LogManager.shared.log("🤖 Starting AI naming...")
        var aiName: String? = nil
        var thumbnailShareURL: String? = nil

        if let aiNameBase = await aiNamingService.generateName(for: fileURL, subtitles: generatedSubtitles) {
            aiName = aiNameBase

            updateRecording(id: id) {
                $0.aiGeneratedName = aiName
            }
            LogManager.shared.log("🤖 AI Naming: ✅ Named: \"\(aiName ?? "")\"")

            // Step 4: Rename on Dropbox if uploaded
            if let currentPath = dropboxPath, !token.isEmpty, let name = aiName {
                do {
                    LogManager.shared.log("📤 Rename: Renaming \"\(currentPath)\" to \"\(name).mp4\"")
                    let newPath = try await dropboxUploadManager.renameFile(
                        fromPath: currentPath,
                        toNewName: name + ".mp4",
                        accessToken: token
                    )
                    updateRecording(id: id) {
                        $0.dropboxPath = newPath
                    }
                    LogManager.shared.log("📤 Rename: ✅ Renamed on Dropbox")
                } catch {
                    LogManager.shared.log(error: error, message: "📤 Rename: ❌ Failed")
                }
            }

            // Step 4b: Generate + upload thumbnail
            if let current = recordings.first(where: { $0.id == id }),
               current.uploadStatus == .uploaded,
               !token.isEmpty,
               let name = aiName {
                thumbnailShareURL = await uploadThumbnail(
                    localVideoURL: fileURL,
                    videoName: name,
                    accessToken: token
                )
                if let thumb = thumbnailShareURL {
                    updateRecording(id: id) {
                        $0.thumbnailURL = thumb
                    }
                }
            }
        }

        // Phase 2: update the registered video with AI data (title, subtitles, thumbnail, final path).
        // Always runs so processingStatus flips to "ready" even when Gemini partially fails.
        if let phase1 = phase1Result {
            let finalTitle = aiName ?? placeholderTitle
            let finalPath = recordings.first(where: { $0.id == id })?.dropboxPath
            await tracerAPIClient.updateVideo(
                slug: phase1.slug,
                title: finalTitle,
                dropboxPath: finalPath,
                transcriptSrt: generatedSubtitles,
                thumbnailURL: thumbnailShareURL.map(Self.toRawDropboxURL)
            )
            LogManager.shared.log("🌐 Tracer: Phase 2 complete — title: \"\(finalTitle)\"")
        } else if tracerAPIClient.isSignedIn,
                  let current = recordings.first(where: { $0.id == id }),
                  let finalPath = current.dropboxPath {
            // Fallback: Phase 1 failed (network error), register now with final data
            let finalTitle = aiName ?? placeholderTitle
            let registered = await tracerAPIClient.registerVideo(
                title: finalTitle,
                dropboxPath: finalPath,
                dropboxSharedURL: current.dropboxSharedURL,
                duration: current.duration,
                fileSize: current.fileSize,
                recordedAt: current.createdAt,
                thumbnailURL: thumbnailShareURL.map(Self.toRawDropboxURL),
                subtitlesSrt: generatedSubtitles
            )
            if let registered = registered {
                updateRecording(id: id) {
                    $0.tracerSlug = registered.slug
                    $0.tracerURL = registered.url
                }
                if let url = URL(string: registered.url) {
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                }
            }
        }

        // Step 5: Delete local file after everything is done
        if dropboxPath != nil {
            try? FileManager.default.removeItem(at: fileURL)
            LogManager.shared.log("🗑️ Local file deleted: \(fileURL.lastPathComponent)")

            // Step 6: Sync Dropbox state to update UI
            await syncDropboxState()
        }
    }

    // MARK: - Thumbnail Upload

    /// Generates a JPG thumbnail from a local video, uploads it to Dropbox next to the video
    /// (named `{videoName}.thumb.jpg`), creates a shared link, and returns the shared URL.
    /// Returns nil on any failure — thumbnail upload must never block video registration.
    private func uploadThumbnail(
        localVideoURL: URL,
        videoName: String,
        accessToken: String
    ) async -> String? {
        guard FileManager.default.fileExists(atPath: localVideoURL.path) else {
            return nil
        }
        do {
            let jpgURL = try await ThumbnailGenerator.generateJPG(from: localVideoURL)
            defer { try? FileManager.default.removeItem(at: jpgURL) }

            let uploadedPath = try await dropboxUploadManager.upload(
                fileURL: jpgURL,
                fileName: "\(videoName).thumb.jpg",
                accessToken: accessToken
            )
            let sharedURL = try await dropboxUploadManager.createSharedLink(
                path: uploadedPath,
                accessToken: accessToken
            )
            LogManager.shared.log("🖼️ Thumbnail: ✅ Uploaded \(uploadedPath)")
            return sharedURL
        } catch {
            LogManager.shared.log(error: error, message: "🖼️ Thumbnail: upload failed")
            return nil
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

    // MARK: - Dropbox Sync

    @MainActor
    func syncDropboxState() async {
        guard dropboxAuthManager.isSignedIn else { return }
        isSyncingDropbox = true
        defer { isSyncingDropbox = false }
        
        guard let token = await dropboxAuthManager.refreshTokenIfNeeded() ?? dropboxAuthManager.accessToken else { return }
        
        do {
            // 1. Storage
            let space = try await dropboxUploadManager.getSpaceUsage(accessToken: token)
            self.dropboxUsedSpace = space.used
            self.dropboxAllocatedSpace = space.allocated
            UserDefaults.standard.set(Double(space.used), forKey: Self.dropboxUsedSpaceKey)
            UserDefaults.standard.set(Double(space.allocated), forKey: Self.dropboxAllocatedSpaceKey)
            
            // 2. Fetch list & links
            async let filesTask = dropboxUploadManager.listFolder(path: "", accessToken: token)
            async let linksTask = dropboxUploadManager.listAllSharedLinks(accessToken: token)
            
            let files = try await filesTask
            let links = try await linksTask
            
            // 3. Process into Recordings
            var syncedRecordings: [Recording] = []
            let df = ISO8601DateFormatter()
            
            for file in files {
                let lowerPath = file.pathDisplay.lowercased()
                let sharedUrl = links[lowerPath]
                let date = df.date(from: file.clientModified) ?? Date()
                
                var existingID = UUID()
                var existingDuration: TimeInterval? = nil
                var existingTracerSlug: String? = nil
                var existingTracerURL: String? = nil
                var existingThumbnailURL: String? = nil
                if let matched = self.recordings.first(where: { $0.dropboxPath?.lowercased() == lowerPath }) {
                    existingID = matched.id
                    existingDuration = matched.duration
                    existingTracerSlug = matched.tracerSlug
                    existingTracerURL = matched.tracerURL
                    existingThumbnailURL = matched.thumbnailURL
                }

                let fakeURL = URL(fileURLWithPath: "/tmp/\(file.name)")
                let finalDuration = file.duration ?? existingDuration ?? 0
                var rec = Recording(id: existingID, fileURL: fakeURL, createdAt: date, duration: finalDuration, uploadStatus: .uploaded)
                rec.dropboxPath = file.pathDisplay
                rec.dropboxSharedURL = sharedUrl
                rec.fileSize = file.size
                rec.tracerSlug = existingTracerSlug
                rec.tracerURL = existingTracerURL
                rec.thumbnailURL = existingThumbnailURL
                
                let baseName = (file.name as NSString).deletingPathExtension
                if !baseName.starts(with: "Recording_") {
                    rec.aiGeneratedName = baseName
                }
                
                syncedRecordings.append(rec)
            }
            
            // Fetch duration for files where Dropbox didn't return media_info
            for i in syncedRecordings.indices where syncedRecordings[i].duration == 0 {
                if let path = syncedRecordings[i].dropboxPath,
                   let dur = await dropboxUploadManager.getFileDuration(path: path, accessToken: token),
                   dur > 0 {
                    syncedRecordings[i].duration = dur
                }
            }

            // Sort synced by date descending
            syncedRecordings.sort { $0.createdAt > $1.createdAt }
            
            // 4. Merge with local active ones (e.g. uploading/failed)
            let activeLocal = self.recordings.filter { $0.uploadStatus != .uploaded && $0.uploadStatus != .notUploaded }
            self.recordings = activeLocal + syncedRecordings
            
            saveRecordings()
            
        } catch {
            print("❌ Dropbox Sync Failed: \(error)")
        }
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
        // 1. Delete from remote if uploaded
        if let path = recording.dropboxPath, dropboxAuthManager.isSignedIn {
            do {
                let token = await dropboxAuthManager.refreshTokenIfNeeded() ?? dropboxAuthManager.accessToken ?? ""
                try await dropboxUploadManager.deleteFile(path: path, accessToken: token)
                print("🗑️ Remote: Deleted \(path)")
            } catch {
                print("❌ Remote Delete Failed: \(error)")
            }
        }
        
        // 2. Delete local if exists
        if FileManager.default.fileExists(atPath: recording.fileURL.path) {
            try? FileManager.default.removeItem(at: recording.fileURL)
        }
        
        // 3. Remove from state
        DispatchQueue.main.async {
            self.recordings.removeAll { $0.id == recording.id }
            self.saveRecordings()
        }
        
        // 4. Sync storage info
        await syncDropboxState()
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
        if let url = URL(string: "https://tracer.nocorny.com/dashboard/settings") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Tracer → Dropbox sync

    /// Fetches the Dropbox access token that Tracer issues for the signed-in user,
    /// and activates proxied mode in the DropboxAuthManager. Called after Tracer sign-in.
    @MainActor
    func syncDropboxFromTracer() async {
        guard tracerAPIClient.isSignedIn else { return }
        guard let result = await tracerAPIClient.fetchDropboxAccessToken(),
              result.connected, let token = result.accessToken else {
            dropboxAuthManager.clearProxiedState()
            return
        }
        let expiresAt = result.expiresAt.flatMap { ISO8601DateFormatter().date(from: $0) }
        await dropboxAuthManager.applyProxiedToken(accessToken: token, expiresAt: expiresAt)
    }

    /// Pulls the user's registered videos from Tracer and replaces the local list.
    /// Called after Tracer sign-in so the Recordings tab reflects server state
    /// instead of stale Dropbox-scanned results.
    @MainActor
    func reloadRecordingsFromTracer() async {
        guard tracerAPIClient.isSignedIn else { return }
        let serverVideos = await tracerAPIClient.listVideos()
        guard !serverVideos.isEmpty else { return }

        let mapped: [Recording] = serverVideos.map { v in
            let id = UUID()
            let fakeURL = URL(fileURLWithPath: "/tmp/\(v.slug).mp4")
            let created = v.recordedAt ?? v.createdAt ?? Date()
            var rec = Recording(
                id: id,
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
            rec.fileSize = v.fileSize.map { UInt64($0) }
            return rec
        }

        let activeLocal = recordings.filter { $0.uploadStatus != .uploaded && $0.uploadStatus != .notUploaded }
        recordings = activeLocal + mapped.sorted { $0.createdAt > $1.createdAt }
        saveRecordings()
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
