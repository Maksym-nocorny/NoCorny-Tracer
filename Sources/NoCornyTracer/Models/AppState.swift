import Foundation
import SwiftUI
import Combine
import ServiceManagement

/// Central app state managing all sub-managers and user preferences
@Observable
final class AppState: @unchecked Sendable {
    // MARK: - Managers
    let recordingManager = RecordingManager()
    let dropboxAuthManager = DropboxAuthManager()
    let dropboxUploadManager = DropboxUploadManager()
    let aiNamingService = AINamingService()
    let hotkeyManager = HotkeyManager()
    let cameraManager = CameraManager()

    // MARK: - State
    var recordings: [Recording] = []
    var dropboxUsedSpace: UInt64 = 0
    var dropboxAllocatedSpace: UInt64 = 0
    var isSyncingDropbox: Bool = false
    
    var showSettings = false
    var selectedMicrophoneID: String?
    var isMicrophoneEnabled: Bool = true
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

    /// Set to true on first launch to show a dialog asking about launch at login
    var showLaunchAtLoginPrompt = false

    init() {
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

        // Step 1: Upload to Dropbox immediately with default timestamp name
        var dropboxPath: String?
        var token = ""

        if autoUploadEnabled && dropboxAuthManager.isSignedIn {
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

        // Step 2: Generate and upload subtitles
        LogManager.shared.log("🤖 Starting subtitle generation...")
        var generatedSubtitles: String? = nil
        
        if let subtitles = await aiNamingService.generateSubtitles(for: fileURL) {
            generatedSubtitles = subtitles
            LogManager.shared.log("🤖 Subtitles: ✅ Generated content length: \(subtitles.count)")
            
            if !token.isEmpty {
                // Fetch fresh display name
                let currentRecording = recordings.first(where: { $0.id == id })
                let srtFileName = (currentRecording?.displayName ?? "Recording") + ".srt"
                
                do {
                    _ = try await dropboxUploadManager.uploadTextFile(
                        content: subtitles,
                        fileName: srtFileName,
                        accessToken: token
                    )
                    LogManager.shared.log("📤 Subtitles: ✅ Uploaded as \"\(srtFileName)\"")
                } catch {
                    LogManager.shared.log(error: error, message: "📤 Subtitles: ❌ Upload failed")
                }
            }
        }

        // Step 3: AI Naming (using frames + subtitles)
        LogManager.shared.log("🤖 Starting AI naming...")
        if let aiNameBase = await aiNamingService.generateName(for: fileURL, subtitles: generatedSubtitles) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "dd MMMM yyyy - HH.mm"
            
            // Get creation date from state
            let creationDate = (recordings.first(where: { $0.id == id })?.createdAt) ?? Date()
            let dateString = formatter.string(from: creationDate)
            let aiName = "\(aiNameBase) \(dateString)"
            
            updateRecording(id: id) {
                $0.aiGeneratedName = aiName
            }
            LogManager.shared.log("🤖 AI Naming: ✅ Named: \"\(aiName)\"")

            // Step 4: Rename on Dropbox if uploaded
            if let currentPath = dropboxPath, !token.isEmpty {
                do {
                    LogManager.shared.log("📤 Rename: Renaming \"\(currentPath)\" to \"\(aiName).mp4\"")
                    let newPath = try await dropboxUploadManager.renameFile(
                        fromPath: currentPath,
                        toNewName: aiName + ".mp4",
                        accessToken: token
                    )
                    updateRecording(id: id) {
                        $0.dropboxPath = newPath
                    }
                    LogManager.shared.log("📤 Rename: ✅ Renamed on Dropbox")
                    
                    // Automatically open the Dropbox link in the browser
                    if let currentRecording = recordings.first(where: { $0.id == id }),
                       let url = currentRecording.shareURL {
                        DispatchQueue.main.async {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } catch {
                    LogManager.shared.log(error: error, message: "📤 Rename: ❌ Failed")
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
                if let matched = self.recordings.first(where: { $0.dropboxPath?.lowercased() == lowerPath }) {
                    existingID = matched.id
                    existingDuration = matched.duration
                }
                
                let fakeURL = URL(fileURLWithPath: "/tmp/\(file.name)")
                let finalDuration = file.duration ?? existingDuration ?? 0
                var rec = Recording(id: existingID, fileURL: fakeURL, createdAt: date, duration: finalDuration, uploadStatus: .uploaded)
                rec.dropboxPath = file.pathDisplay
                rec.dropboxSharedURL = sharedUrl
                rec.fileSize = file.size
                
                let baseName = (file.name as NSString).deletingPathExtension
                if !baseName.starts(with: "Recording_") {
                    rec.aiGeneratedName = baseName
                }
                
                syncedRecordings.append(rec)
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
